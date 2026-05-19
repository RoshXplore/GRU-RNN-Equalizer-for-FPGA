`timescale 1ns / 1ps

module linear_layer_backward #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_SIZE = 3,
    parameter OUTPUT_SIZE = 2
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,
    
    input wire [(INPUT_SIZE*DATA_WIDTH)-1:0] i_input_vector_flat,
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_grad_output_flat,
    input wire [(INPUT_SIZE*OUTPUT_SIZE*DATA_WIDTH)-1:0] i_fc_weights_flat,
    
    output reg [(INPUT_SIZE*OUTPUT_SIZE*DATA_WIDTH)-1:0] o_grad_weights_flat,
    output reg [(OUTPUT_SIZE*DATA_WIDTH)-1:0] o_grad_bias_flat,
    output reg [(INPUT_SIZE*DATA_WIDTH)-1:0] o_grad_input_flat
);

    localparam S_IDLE = 4'd0,
               S_COMPUTE_BIAS_GRAD = 4'd1,
               S_COMPUTE_WEIGHT_GRAD = 4'd2,
               S_MULT_WEIGHT_GRAD = 4'd3,
               S_MULT_WEIGHT_GRAD_WAIT = 4'd4,
               S_COMPUTE_INPUT_GRAD = 4'd5,
               S_MULT_INPUT_GRAD = 4'd6,
               S_MULT_INPUT_GRAD_WAIT = 4'd7,
               S_ACC_INPUT_GRAD = 4'd8,
               S_ACC_INPUT_GRAD_WAIT = 4'd9,
               S_DONE = 4'd10;
    
    reg [3:0] state;
    reg [7:0] out_idx, in_idx;
    reg mult_start, add_start;
    wire mult_done, add_done;
    reg [DATA_WIDTH-1:0] mult_a, mult_b, add_a, add_b;
    wire [DATA_WIDTH-1:0] mult_result, add_result;
    reg [(INPUT_SIZE*DATA_WIDTH)-1:0] grad_input_buffer;
    
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) grad_mult (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_a), .x(mult_b), .mult_result(mult_result));
    adder #(.DATA_WIDTH(DATA_WIDTH)) grad_adder (.clk(clk), .rstn(rstn), .start(add_start), .done(add_done), .value_in(add_a), .bias(add_b), .value_out(add_result));
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 0; mult_start <= 0; add_start <= 0;
            out_idx <= 0; in_idx <= 0;
            o_grad_weights_flat <= 0; o_grad_bias_flat <= 0; o_grad_input_flat <= 0;
            grad_input_buffer <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    mult_start <= 0; add_start <= 0; o_done <= 0;
                    if (i_start) begin
                        out_idx <= 0; in_idx <= 0; 
                        grad_input_buffer <= 0; 
                        state <= S_COMPUTE_BIAS_GRAD;
                    end
                end
                
                S_COMPUTE_BIAS_GRAD: begin
                    o_grad_bias_flat <= i_grad_output_flat;
                    out_idx <= 0; in_idx <= 0;
                    state <= S_COMPUTE_WEIGHT_GRAD;
                end
                
                S_COMPUTE_WEIGHT_GRAD: begin
                    if (out_idx < OUTPUT_SIZE) begin
                        if (in_idx < INPUT_SIZE) begin
                            mult_a <= i_grad_output_flat[out_idx*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= i_input_vector_flat[in_idx*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            state <= S_MULT_WEIGHT_GRAD;
                        end else begin
                            in_idx <= 0; out_idx <= out_idx + 1;
                        end
                    end else begin
                        in_idx <= 0; out_idx <= 0;
                        state <= S_COMPUTE_INPUT_GRAD;
                    end
                end
                
                S_MULT_WEIGHT_GRAD: begin
                    if (mult_done) begin
                        o_grad_weights_flat[(out_idx*INPUT_SIZE + in_idx)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                        mult_start <= 0;
                        state <= S_MULT_WEIGHT_GRAD_WAIT;
                    end else mult_start <= 1;
                end
                S_MULT_WEIGHT_GRAD_WAIT: begin mult_start <= 0; if (!mult_done) begin in_idx <= in_idx + 1; state <= S_COMPUTE_WEIGHT_GRAD; end end
                
                S_COMPUTE_INPUT_GRAD: begin
                    if (in_idx < INPUT_SIZE) begin
                        if (out_idx < OUTPUT_SIZE) begin
                            mult_a <= i_fc_weights_flat[(out_idx*INPUT_SIZE + in_idx)*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= i_grad_output_flat[out_idx*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            state <= S_MULT_INPUT_GRAD;
                        end else begin
                            o_grad_input_flat[in_idx*DATA_WIDTH +: DATA_WIDTH] <= grad_input_buffer[in_idx*DATA_WIDTH +: DATA_WIDTH];
                            out_idx <= 0; in_idx <= in_idx + 1;
                        end
                    end else begin
                        state <= S_DONE;
                    end
                end
                
                S_MULT_INPUT_GRAD: begin
                    if (mult_done) begin
                        add_a <= grad_input_buffer[in_idx*DATA_WIDTH +: DATA_WIDTH];
                        add_b <= mult_result;
                        mult_start <= 0;
                        state <= S_MULT_INPUT_GRAD_WAIT;
                    end else mult_start <= 1;
                end
                S_MULT_INPUT_GRAD_WAIT: begin mult_start <= 0; if (!mult_done) begin add_start <= 1; state <= S_ACC_INPUT_GRAD; end end
                
                S_ACC_INPUT_GRAD: begin
                    if (add_done) begin
                        grad_input_buffer[in_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                        add_start <= 0;
                        state <= S_ACC_INPUT_GRAD_WAIT;
                    end else add_start <= 1;
                end
                S_ACC_INPUT_GRAD_WAIT: begin add_start <= 0; if (!add_done) begin out_idx <= out_idx + 1; state <= S_COMPUTE_INPUT_GRAD; end end
                
                S_DONE: begin
                    o_done <= 1;
                    if (!i_start) begin
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end


//    //DEBUG PROBE

//    reg prev_done;
//    always @(posedge clk) begin
//        if (rstn) begin
//            if (o_done && !prev_done) begin
//                $display("\n[LINEAR BACKWARD DONE]");
//                // Print the gradient vector being passed to GRU
//                // Assuming 3 hidden units (INPUT_SIZE = 3)
//                $display("   dLoss/dh[0] : %h", o_grad_input_flat[31:0]);
//                $display("   dLoss/dh[1] : %h", o_grad_input_flat[63:32]);
//                $display("   dLoss/dh[2] : %h", o_grad_input_flat[95:64]);
//            end
//            prev_done <= o_done;
//        end
//    end

endmodule