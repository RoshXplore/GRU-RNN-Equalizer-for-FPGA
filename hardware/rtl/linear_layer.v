`timescale 1ns / 1ps

module linear_layer #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_VECTOR_SIZE = 3,
    parameter OUTPUT_SIZE = 2
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,

    input wire [(INPUT_VECTOR_SIZE * DATA_WIDTH)-1:0] i_input_vector_flat,
    input wire [(INPUT_VECTOR_SIZE * OUTPUT_SIZE * DATA_WIDTH)-1:0] i_fc_weights_flat,
    input wire [(OUTPUT_SIZE * DATA_WIDTH)-1:0] i_fc_bias_flat,
    output reg [(OUTPUT_SIZE * DATA_WIDTH)-1:0] o_final_prediction
);

    localparam S_IDLE         = 4'd0,
               S_START_DP_I   = 4'd1,
               S_WAIT_DP_I    = 4'd2,
               S_WAIT_DP_I_ACK = 4'd3,
               S_START_ADD_I  = 4'd4,
               S_WAIT_ADD_I   = 4'd5,
               S_WAIT_ADD_I_ACK = 4'd6,
               S_START_DP_Q   = 4'd7,
               S_WAIT_DP_Q    = 4'd8,
               S_WAIT_DP_Q_ACK = 4'd9,
               S_START_ADD_Q  = 4'd10,
               S_WAIT_ADD_Q   = 4'd11,
               S_WAIT_ADD_Q_ACK = 4'd12,
               S_DONE         = 4'd13;
    reg [3:0] state;

    reg dp_start, add_start;
    wire dp_done, add_done;
    wire [DATA_WIDTH-1:0] dp_result;
    wire [DATA_WIDTH-1:0] final_add_result_wire;
    reg [DATA_WIDTH-1:0] prediction_I, prediction_Q;
    reg [(INPUT_VECTOR_SIZE * DATA_WIDTH)-1:0] dp_weights;
    reg [DATA_WIDTH-1:0] add_bias;

    dot_product #(.MAX_VECTOR_SIZE(INPUT_VECTOR_SIZE)) fc_dot_product (
        .clk(clk), .rstn(rstn), .start(dp_start), .done(dp_done),
        .vector_length(INPUT_VECTOR_SIZE[3:0]), .vector_a_flat(i_input_vector_flat), .vector_b_flat(dp_weights), .result(dp_result)
    );
    adder #(.DATA_WIDTH(DATA_WIDTH)) fc_adder (
        .clk(clk), .rstn(rstn), .start(add_start), .done(add_done),
        .value_in(dp_result), .bias(add_bias), .value_out(final_add_result_wire)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 1'b0;
            dp_start <= 1'b0; add_start <= 1'b0;
            o_final_prediction <= 0; prediction_I <= 0; prediction_Q <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_done <= 1'b0; dp_start <= 1'b0; add_start <= 1'b0;
                    if (i_start) begin
                        
                        state <= S_START_DP_I;
                    end
                end
                
                S_START_DP_I: begin dp_weights <= i_fc_weights_flat[0 +: INPUT_VECTOR_SIZE*DATA_WIDTH]; dp_start <= 1'b1; state <= S_WAIT_DP_I; end
                S_WAIT_DP_I: begin dp_start <= 1'b1; if (dp_done) begin dp_start <= 1'b0; state <= S_WAIT_DP_I_ACK; end end
                S_WAIT_DP_I_ACK: begin dp_start <= 1'b0; if (!dp_done) state <= S_START_ADD_I; end
                
                S_START_ADD_I: begin add_bias <= i_fc_bias_flat[0*DATA_WIDTH +: DATA_WIDTH]; add_start <= 1'b1; state <= S_WAIT_ADD_I; end
                S_WAIT_ADD_I: begin add_start <= 1'b1; if (add_done) begin prediction_I <= final_add_result_wire; add_start <= 1'b0; state <= S_WAIT_ADD_I_ACK; end end
                S_WAIT_ADD_I_ACK: begin add_start <= 1'b0; if (!add_done) state <= S_START_DP_Q; end
                
                S_START_DP_Q: begin dp_weights <= i_fc_weights_flat[INPUT_VECTOR_SIZE*DATA_WIDTH +: INPUT_VECTOR_SIZE*DATA_WIDTH]; dp_start <= 1'b1; state <= S_WAIT_DP_Q; end
                S_WAIT_DP_Q: begin dp_start <= 1'b1; if (dp_done) begin dp_start <= 1'b0; state <= S_WAIT_DP_Q_ACK; end end
                S_WAIT_DP_Q_ACK: begin dp_start <= 1'b0; if (!dp_done) state <= S_START_ADD_Q; end
                
                S_START_ADD_Q: begin add_bias <= i_fc_bias_flat[1*DATA_WIDTH +: DATA_WIDTH]; add_start <= 1'b1; state <= S_WAIT_ADD_Q; end
                S_WAIT_ADD_Q: begin add_start <= 1'b1; if (add_done) begin prediction_Q <= final_add_result_wire; add_start <= 1'b0; state <= S_WAIT_ADD_Q_ACK; end end
                S_WAIT_ADD_Q_ACK: begin
                    add_start <= 1'b0;
                    if (!add_done) begin
                        o_final_prediction[0*DATA_WIDTH +: DATA_WIDTH] <= prediction_I;
                        o_final_prediction[1*DATA_WIDTH +: DATA_WIDTH] <= prediction_Q;
                        
                        state <= S_DONE;
                    end
                end
                
                
                S_DONE: begin
                    o_done <= 1'b1;
                    dp_start <= 1'b0; add_start <= 1'b0;
                    if (!i_start) begin
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule