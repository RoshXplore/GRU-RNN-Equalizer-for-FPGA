`timescale 1ns / 1ps

module fpu (
    input wire clk_i,
    input wire rstn_i,          // ADDED: A reset is essential for FSMs
    input wire [31:0] opa_i,
    input wire [31:0] opb_i,
    input wire [2:0] fpu_op_i,
    input wire [1:0] rmode_i,
    input wire start_i,
    output [31:0] output_o,
    output reg ready_o,
    output ine_o,
    output overflow_o,
    output underflow_o,
    output div_zero_o,
    output inf_o,
    output zero_o,
    output qnan_o,
    output snan_o

);

    parameter EXP_WIDTH = 7;
    parameter FP_WIDTH = 32;
    parameter FRAC_WIDTH = 23;

    // Input/output registers
    reg [FP_WIDTH-1:0] s_opa_i, s_opb_i;
    reg [2:0] s_fpu_op_i;
    reg [1:0] s_rmode_i;
    wire [FP_WIDTH-1:0] s_output1;

    // FSM state
    parameter waiting = 1'b0;
    parameter busy = 1'b1;
    reg s_state;
    reg [2:0] s_count;

    // Add/Substract units signals
    wire [27:0] prenorm_addsub_fracta_28_o, prenorm_addsub_fractb_28_o;
    wire [7:0] prenorm_addsub_exp_o;
    wire [27:0] addsub_fract_o;
    wire [26:0] sum_o1;
    wire co_o1;
    wire addsub_sign_o;
    wire [31:0] postnorm_addsub_output_o;
    wire postnorm_addsub_ine_o;
    wire sign_o1;
    wire fasu_op;

    // Multiply units signals
    wire [9:0] pre_norm_mul_exp_10;
    wire [23:0] pre_norm_mul_fracta_24, pre_norm_mul_fractb_24;
    wire pre_norm_mul_sign;
    wire [1:0] pre_norm_mul_exp_ovf;
    wire [47:0] serial_mul_fract_48;
    wire [31:0] post_norm_mul_output;
    
    // Unused signals from original code (assuming for future use)
    wire serial_div_div_zero;

    wire s_infa, s_infb;

    // Sub-module Instantiations
    pre_norm_addsub2 pre_norm_addsub_inst (
        .clk(clk_i),
        .add(!s_fpu_op_i[0]),
        .opa(s_opa_i),
        .opb(s_opb_i),
        .fracta_out(prenorm_addsub_fracta_28_o),
        .fractb_out(prenorm_addsub_fractb_28_o),
        .exp_dn_out(prenorm_addsub_exp_o),
        .sign(sign_o1),
        .fasu_op(fasu_op)
    );

    addsub_281 addsub_inst(
        .add(fasu_op),
        .opa(prenorm_addsub_fracta_28_o),
        .opb(prenorm_addsub_fractb_28_o),
        .sum(sum_o1),
        .co(co_o1)
    );

    assign addsub_fract_o = {co_o1, sum_o1};

    post_norm_addsub post_norm_addsub_inst (
        .clk_i(clk_i),
        .opa_i(s_opa_i),
        .opb_i(s_opb_i),
        .fract_28_i(addsub_fract_o),
        .exp_i(prenorm_addsub_exp_o),
        .sign_i(sign_o1),
        .fpu_op_i(s_fpu_op_i[0]),
        .rmode_i(s_rmode_i),
        .output_o(postnorm_addsub_output_o),
        .ine_o(postnorm_addsub_ine_o)
    );

    pre_norm_mul1 pre_norm_mul_inst (
        .clk_i(clk_i),
        .opa_i(s_opa_i),
        .opb_i(s_opb_i),
        .exp_10_o(pre_norm_mul_exp_10),
        .fracta_24_o(pre_norm_mul_fracta_24),
        .fractb_24_o(pre_norm_mul_fractb_24),
        .sign(pre_norm_mul_sign),
        .exp_ovf(pre_norm_mul_exp_ovf)
    );

    mul mul_inst(
        .clk_i(clk_i),
        .fracta_i(pre_norm_mul_fracta_24),
        .fractb_i(pre_norm_mul_fractb_24),
        .fract_o(serial_mul_fract_48)
    );

    post_norm_mul1 post_norm_mul_inst (
        .clk_i(clk_i),
        .opa_i(s_opa_i),
        .opb_i(s_opb_i),
        .exp_10_i(pre_norm_mul_exp_10),
        .fract_48_i(serial_mul_fract_48),
        .rmode_i(s_rmode_i),
        .exp_ovf(pre_norm_mul_exp_ovf),
        .sign_i(pre_norm_mul_sign),
        .output_o(post_norm_mul_output)
    );


    // Input Register
    always @(posedge clk_i) begin
        // Only latch new inputs when a start signal is detected and we are in the waiting state
        if (start_i && s_state == waiting) begin
            s_opa_i <= opa_i;
            s_opb_i <= opb_i;
            s_fpu_op_i <= fpu_op_i;
            s_rmode_i <= rmode_i;
        end
    end

    // CORRECTED FSM
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            s_state <= waiting;
            ready_o <= 1'b0;
            s_count <= 0;
        end else begin
            case (s_state)
                waiting: begin
                    ready_o <= 1'b0; // Keep ready low while waiting
                    if (start_i) begin
                        s_state <= busy;
                        s_count <= 0; // Reset counter for the new operation
                    end
                end
                
                busy: begin
                    // Check if the operation is complete based on the latched operation type
                    // Addition takes 4 cycles (count reaches 3)
                    // Multiplication takes 2 cycles (count reaches 1)
                    if ((s_count == 3 && (s_fpu_op_i == 3'b000 || s_fpu_op_i == 3'b001)) ||
                        (s_count == 1 && s_fpu_op_i == 3'b010)) begin
                        s_state <= waiting; // Go back to waiting for the next job
                        ready_o <= 1'b1;    // Signal that we are done!
                    end else begin
                        s_count <= s_count + 1'b1; // Otherwise, keep counting
                    end
                end

                default: begin // Good practice to have a default case
                    s_state <= waiting;
                end
            endcase
        end
    end
                
    // Output Assignment Logic
    assign s_output1 = (s_fpu_op_i == 3'b000 || s_fpu_op_i == 3'b001) ? postnorm_addsub_output_o :
                       (s_fpu_op_i == 3'b010) ? post_norm_mul_output :
                       32'b0; // Default case

    assign s_infa = (opa_i[30:23] == 8'hFF);
    assign s_infb = (opb_i[30:23] == 8'hFF);
    assign output_o = s_output1; // Simplified for now, can add rounding mode logic back later

    assign ine_o = (s_fpu_op_i == 3'b000 || s_fpu_op_i == 3'b001) ? postnorm_addsub_ine_o : 1'b0;

    // Exception Logic (Combinational Logic)
    assign underflow_o = (output_o[30:23] == 8'b00000000 && ine_o);
    assign overflow_o  = (output_o[30:23] == 8'b11111111 && ine_o);
    assign div_zero_o  = (serial_div_div_zero && s_fpu_op_i == 3'b011);
    assign inf_o       = (output_o[30:23] == 8'b11111111 && !(qnan_o || snan_o));
    assign zero_o      = (output_o[30:0] == 31'b0);
    // Simplified NaN logic for clarity
    assign qnan_o      = (output_o[30:23] == 8'hFF && output_o[22] == 1); 
    assign snan_o      = (opa_i[30:23] == 8'hFF && opa_i[22] == 0 && opa_i[21:0] != 0) ||
                       (opb_i[30:23] == 8'hFF && opb_i[22] == 0 && opb_i[21:0] != 0);

endmodule