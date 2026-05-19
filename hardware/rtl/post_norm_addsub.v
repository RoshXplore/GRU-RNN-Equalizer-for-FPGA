`timescale 1ns / 1ps

module post_norm_addsub (
    input clk_i,
    input [31:0] opa_i,
    input [31:0] opb_i,
    input [27:0] fract_28_i,
    input [7:0] exp_i,
    input sign_i,
    input fpu_op_i,
    input [1:0] rmode_i,
    output reg [31:0] output_o,
    output reg ine_o
);

    parameter FP_WIDTH = 32;
    parameter FRAC_WIDTH = 23;
    parameter EXP_WIDTH = 8;

    reg [FP_WIDTH-1:0] s_opa_i, s_opb_i;
    reg [FRAC_WIDTH+4:0] s_fract_28_i;
    reg [EXP_WIDTH-1:0] s_exp_i;
    reg s_sign_i;
    reg s_fpu_op_i;
    reg [1:0] s_rmode_i;

    reg [31:0] s_output_o;
    reg s_ine_o;
    reg s_overflow;

    reg [5:0] s_zeros;
    reg [5:0] s_shr1, s_shl1;
    reg s_shr2, s_carry;
    reg [9:0] s_exp10;
    reg [EXP_WIDTH:0] s_expo9_1, s_expo9_2, s_expo9_3;
    reg [FRAC_WIDTH+4:0] s_fracto28_1, s_fracto28_rnd, s_fracto28_2;
    reg s_roundup, s_sticky, s_zero_fract, s_lost;
    reg [5:0] fi_ldz;
    reg final_sign;

    wire s_infa, s_infb, s_nan_in, s_nan_op, s_nan_a, s_nan_b, s_nan_sign;

    always @(posedge clk_i) begin
        s_opa_i <= opa_i;
        s_opb_i <= opb_i;
        s_fract_28_i <= fract_28_i;
        s_exp_i <= exp_i;
        s_sign_i <= sign_i;
        s_fpu_op_i <= fpu_op_i;
        s_rmode_i <= rmode_i;
    end

    always @(posedge clk_i) begin
        output_o <= s_output_o;
        ine_o <= s_ine_o;
    end
    
    always @(s_fract_28_i)
    casex(s_fract_28_i[26:0])
        27'b1??????????????????????????: fi_ldz = 0; 27'b01?????????????????????????: fi_ldz = 1;
        27'b001????????????????????????: fi_ldz = 2; 27'b0001???????????????????????: fi_ldz = 3;
        27'b00001??????????????????????: fi_ldz = 4; 27'b000001?????????????????????: fi_ldz = 5;
        27'b0000001????????????????????: fi_ldz = 6; 27'b00000001???????????????????: fi_ldz = 7;
        27'b000000001??????????????????: fi_ldz = 8; 27'b0000000001?????????????????: fi_ldz = 9;
        27'b00000000001????????????????: fi_ldz = 10; 27'b000000000001???????????????: fi_ldz = 11;
        27'b0000000000001??????????????: fi_ldz = 12; 27'b00000000000001?????????????: fi_ldz = 13;
        27'b000000000000001????????????: fi_ldz = 14; 27'b0000000000000001???????????: fi_ldz = 15;
        27'b00000000000000001??????????: fi_ldz = 16; 27'b000000000000000001?????????: fi_ldz = 17;
        27'b0000000000000000001????????: fi_ldz = 18; 27'b00000000000000000001???????: fi_ldz = 19;
        27'b000000000000000000001??????: fi_ldz = 20; 27'b0000000000000000000001?????: fi_ldz = 21;
        27'b00000000000000000000001????: fi_ldz = 22; 27'b000000000000000000000001???: fi_ldz = 23;
        27'b0000000000000000000000001??: fi_ldz = 24; 27'b00000000000000000000000001?: fi_ldz = 25;
        27'b000000000000000000000000001: fi_ldz = 26; 27'b000000000000000000000000000: fi_ldz = 27;
        default: fi_ldz = 27;
    endcase

    always @* begin
        s_carry = s_fract_28_i[27];
        s_zeros = (s_fract_28_i[27] == 1'b0)? fi_ldz: 6'b0;
        s_exp10 = {2'b0, s_exp_i} + {9'b0, s_carry} - {4'b0, s_zeros};
        if (s_exp10[9] || s_exp_i == 8'h00) begin
            s_shr1 = 6'b0;
            s_shl1 = (|s_exp_i != 0) ? (s_exp_i[5:0] - 1'b1) : 6'b0;
            s_expo9_1 = 9'd1;
        end else if (s_exp10[8] || s_exp_i == 8'hFF) begin
            s_shr1 = 6'b0;
            s_shl1 = 6'b0;
            s_expo9_1 = 9'd255;
        end else begin
            s_shr1 = {5'b0, s_carry};
            s_shl1 = s_zeros;
            s_expo9_1 = s_exp10[8:0];
        end
    end

    always @(posedge clk_i) begin
        s_fracto28_1 <= (s_shr1 != 6'b0) ? (s_fract_28_i >> s_shr1) : (s_fract_28_i << s_shl1);
    end

    always @* begin
        s_expo9_2 = (s_fracto28_1[27:26] == 2'b00) ? (s_expo9_1 - 1) : s_expo9_1;
    end

    always @* begin
        s_sticky = s_fracto28_1[0] || (s_fract_28_i[0] && s_fract_28_i[27]);
        case (s_rmode_i)
            2'b00: s_roundup = s_fracto28_1[2] && (s_fracto28_1[1] || s_sticky || s_fracto28_1[3]);
            2'b10: s_roundup = (s_fracto28_1[2] || s_fracto28_1[1] || s_sticky) && (!s_sign_i);
            2'b11: s_roundup = (s_fracto28_1[2] || s_fracto28_1[1] || s_sticky) && s_sign_i;
            default: s_roundup = 1'b0;
        endcase
        s_fracto28_rnd = s_roundup ? s_fracto28_1 + 28'h0000004 : s_fracto28_1;
    end

    always @* begin
        s_shr2 = s_fracto28_rnd[27];
        s_expo9_3 = (s_shr2 && (s_expo9_2 != 9'd255)) ? (s_expo9_2 + 1) : s_expo9_2;
        s_fracto28_2 = s_shr2 ? {1'b0, s_fracto28_rnd[27:1]} : s_fracto28_rnd;
    end

    assign s_infa = (s_opa_i[30:23] == 8'hFF);
    assign s_infb = (s_opb_i[30:23] == 8'hFF);
    assign s_nan_a = (s_infa && |s_opa_i[22:0]);
    assign s_nan_b = (s_infb && |s_opb_i[22:0]);
    assign s_nan_in = s_nan_a || s_nan_b;
    assign s_nan_op = (s_infa && s_infb && (s_opa_i[31] != s_opb_i[31]));
    assign s_nan_sign = (s_nan_a && s_nan_b) ? s_sign_i : (s_nan_a ? s_opa_i[31] : s_opb_i[31]);

    always @* begin
        s_lost = (s_shr1[0] && s_fract_28_i[0]) || (s_shr2 && s_fracto28_rnd[0]) || |s_fracto28_2[2:0];
        s_ine_o = (s_lost || s_overflow) && !(s_infa || s_infb);
        s_zero_fract = !(|s_fract_28_i);
        // FINAL FIX #1: This robustly detects when the final exponent is too large
        s_overflow = (s_expo9_3[8] || s_expo9_3[7:0] == 8'hFF) && !(s_infa || s_infb);
    end

    always @* begin
        if (s_infa && !s_infb) begin
            final_sign = s_opa_i[31];
        end else if (!s_infa && s_infb) begin
            final_sign = s_opb_i[31];
        end else begin
            final_sign = s_sign_i;
        end

        if (s_nan_in || s_nan_op) begin
            s_output_o = {s_nan_sign, 8'hFF, 23'h400000};
        end else if (s_infa || s_infb || s_overflow) begin
            // FINAL FIX #2: This ensures the overflow flag correctly generates infinity
            s_output_o = {final_sign, 8'hFF, 23'h0};
        end else if (s_zero_fract) begin
            s_output_o = {s_sign_i, 31'b0};
        end else begin
            s_output_o = {s_sign_i, s_expo9_3[7:0], s_fracto28_2[25:3]};
        end
		  
    end

endmodule