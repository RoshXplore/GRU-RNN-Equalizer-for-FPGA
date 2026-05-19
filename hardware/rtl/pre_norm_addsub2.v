`timescale 1ns / 1ps

module pre_norm_addsub2 (
    input        clk,
    input        add,
    input [31:0] opa, opb,
    output reg [26:0] fracta_out, fractb_out,
    output reg [7:0]  exp_dn_out,
    output reg   sign,
    output reg	 fasu_op
);

    reg add_d;

    wire signa = opa[31];
    wire signb = opb[31];
    wire [7:0] expa = opa[30:23];
    wire [7:0] expb = opb[30:23];
    wire [22:0] fracta = opa[22:0];
    wire [22:0] fractb = opb[22:0];
    
    wire is_inf_a = (expa == 8'hFF);
    wire is_inf_b = (expb == 8'hFF);

    // FIX: Detect if the subtraction will result in a perfect zero
    wire is_exact_zero_sub = (signa != signb) && (expa == expb) && (fracta == fractb);

    wire expa_dn = !(|expa);
    wire expb_dn = !(|expb);
    
    wire expa_lt_expb = expa > expb;
    wire [7:0] exp_small = expa_lt_expb ? expb : expa;
    wire [7:0] exp_large = expa_lt_expb ? expa : expb;
    wire [7:0] exp_diff = exp_large - exp_small;
    wire [7:0] adjusted_exp_diff = (expa_dn | expb_dn) ? (exp_diff - 1) : exp_diff;
    wire [7:0] final_exp_diff = (expa_dn & expb_dn) ? 8'h0 : adjusted_exp_diff;

    always @(posedge clk) begin
        if (is_inf_a || is_inf_b) begin
            exp_dn_out <= 8'hFF;
        end else if (is_exact_zero_sub) begin
            exp_dn_out <= 8'h0;
        end else begin
            exp_dn_out <= exp_large;
        end
    end

    wire op_dn = expa_lt_expb ? expb_dn : expa_dn;
    wire [22:0] adj_op = expa_lt_expb ? fractb : fracta;
    wire [26:0] adj_op_tmp = { ~op_dn, adj_op, 3'b0 };
    
    wire exp_lt_27 = final_exp_diff > 8'd27;
    wire [4:0] exp_diff_sft = exp_lt_27 ? 5'd27 : final_exp_diff[4:0];
    wire [26:0] adj_op_out_sft = adj_op_tmp >> exp_diff_sft;
	reg		sticky;
	
    always @(exp_diff_sft or adj_op_tmp)
    case(exp_diff_sft)
        'd0: sticky = 1'h0; 'd1: sticky = |adj_op_tmp[0:0]; 'd2: sticky = |adj_op_tmp[1:0];
        'd3: sticky = |adj_op_tmp[2:0]; 'd4: sticky = |adj_op_tmp[3:0]; 'd5: sticky = |adj_op_tmp[4:0];
        'd6: sticky = |adj_op_tmp[5:0]; 'd7: sticky = |adj_op_tmp[6:0]; 'd8: sticky = |adj_op_tmp[7:0];
        'd9: sticky = |adj_op_tmp[8:0]; 'd10: sticky = |adj_op_tmp[9:0]; 'd11: sticky = |adj_op_tmp[10:0];
        'd12: sticky = |adj_op_tmp[11:0]; 'd13: sticky = |adj_op_tmp[12:0]; 'd14: sticky = |adj_op_tmp[13:0];
        'd15: sticky = |adj_op_tmp[14:0]; 'd16: sticky = |adj_op_tmp[15:0]; 'd17: sticky = |adj_op_tmp[16:0];
        'd18: sticky = |adj_op_tmp[17:0]; 'd19: sticky = |adj_op_tmp[18:0]; 'd20: sticky = |adj_op_tmp[19:0];
        'd21: sticky = |adj_op_tmp[20:0]; 'd22: sticky = |adj_op_tmp[21:0]; 'd23: sticky = |adj_op_tmp[22:0];
        'd24: sticky = |adj_op_tmp[23:0]; 'd25: sticky = |adj_op_tmp[24:0]; 'd26: sticky = |adj_op_tmp[25:0];
        'd27: sticky = |adj_op_tmp[26:0]; default: sticky = 1'h0;
    endcase
	
	wire [26:0] adj_op_out = { adj_op_out_sft[26:1], adj_op_out_sft[0] | sticky };

    wire [26:0] fracta_n = expa_lt_expb ? {~expa_dn, fracta, 3'b0} : adj_op_out;
    wire [26:0] fractb_n = expa_lt_expb ? adj_op_out : {~expb_dn, fractb, 3'b0};

    wire fractb_lt_fracta = fractb_n > fracta_n;
    wire [26:0] fracta_s = fractb_lt_fracta ? fractb_n : fracta_n;
    wire [26:0] fractb_s = fractb_lt_fracta ? fracta_n : fractb_n;
    
    always @(posedge clk) begin
        fracta_out <= fracta_s;
        fractb_out <= fractb_s;
    end

    reg sign_d;
    always @* begin
        case ({signa, signb, add})
            3'b0_0_1: sign_d = 0;
            3'b0_1_1: sign_d = fractb_lt_fracta;
            3'b1_0_1: sign_d = !fractb_lt_fracta;
            3'b0_0_0: sign_d = fractb_lt_fracta;
            3'b1_1_0: sign_d = !fractb_lt_fracta;
            3'b0_1_0: sign_d = 0;
            3'b1_0_0: sign_d = 1;
            3'b1_1_1: sign_d = 1;
            default:  sign_d = 0;
        endcase
    end

    always @(posedge clk) begin
        // FIX: Force sign to positive for exact zero subtractions to comply with IEEE 754
        if (is_exact_zero_sub) begin
            sign <= 1'b0;
        end else begin
            sign <= sign_d;
        end
    end

    always @* begin
        case ({signa, signb, add})
            3'b0_0_1, 3'b1_1_1, 3'b0_1_0, 3'b1_0_0: add_d = 1;
            3'b0_1_1, 3'b1_0_1, 3'b0_0_0, 3'b1_1_0: add_d = 0;
            default: add_d = 1;
        endcase
    end
    
	always @(posedge clk)
		fasu_op <= add_d;

endmodule