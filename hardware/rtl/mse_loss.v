`timescale 1ns / 1ps

module mse_loss #(
    parameter DATA_WIDTH = 32,
    parameter OUTPUT_SIZE = 2
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,
    
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_prediction,
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_target,
    
    output reg [DATA_WIDTH-1:0] o_loss,
    output reg [(OUTPUT_SIZE*DATA_WIDTH)-1:0] o_gradient
);
    
    reg sub_start, mult_start, add_start;
    wire sub_done, mult_done, add_done;
    reg [DATA_WIDTH-1:0] sub_a, sub_b, mult_a, mult_b, add_a, add_b;
    wire [DATA_WIDTH-1:0] sub_result, mult_result, add_result;
    reg [7:0] idx;
    reg [2:0] state;
    reg [DATA_WIDTH-1:0] diff [0:OUTPUT_SIZE-1];
    reg [DATA_WIDTH-1:0] loss_accum;
    
    subtractor #(.DATA_WIDTH(DATA_WIDTH)) sub_inst (.clk(clk), .rstn(rstn), .start(sub_start), .done(sub_done), .value_a(sub_a), .value_b(sub_b), .value_out(sub_result));
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) mult_inst (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_a), .x(mult_b), .mult_result(mult_result));
    adder #(.DATA_WIDTH(DATA_WIDTH)) add_inst (.clk(clk), .rstn(rstn), .start(add_start), .done(add_done), .value_in(add_a), .bias(add_b), .value_out(add_result));
    
    localparam S_IDLE = 3'd0, S_DIFF = 3'd1, S_SQUARE = 3'd2, 
               S_ACCUM = 3'd3, S_GRAD = 3'd4, S_DONE = 3'd5;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 0;
            sub_start <= 0; mult_start <= 0; add_start <= 0;
            idx <= 0;
            o_loss <= 0;
            o_gradient <= 0;
            loss_accum <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    sub_start <= 0; mult_start <= 0; add_start <= 0;
                    o_done <= 0;
                    if (i_start) begin
                        idx <= 0;
                        loss_accum <= 0;
                        state <= S_DIFF;
                    end
                end
                
                // 1. Compute Diff = Pred - Target
                S_DIFF: begin
                    if (idx < OUTPUT_SIZE) begin
                        sub_a <= i_prediction[idx*DATA_WIDTH +: DATA_WIDTH];
                        sub_b <= i_target[idx*DATA_WIDTH +: DATA_WIDTH];
                        sub_start <= 1;
                        if (sub_done) begin
                            sub_start <= 0;
                            diff[idx] <= sub_result;
                            idx <= idx + 1;
                        end
                    end else begin
                        idx <= 0;
                        state <= S_SQUARE;
                    end
                end
                
                // 2. Compute Squared Error (Diff * Diff)
                S_SQUARE: begin
                    if (idx < OUTPUT_SIZE) begin
                        mult_a <= diff[idx];
                        mult_b <= diff[idx];
                        mult_start <= 1;
                        if (mult_done) begin
                            mult_start <= 0;
                            state <= S_ACCUM;
                        end
                    end else begin
                        // All squares summed. multiply total by 0.5
                        mult_a <= 32'h3F000000;
                        mult_b <= loss_accum;
                        mult_start <= 1;
                        if (mult_done) begin
                            mult_start <= 0;
                            o_loss <= mult_result;
                            idx <= 0;
                            state <= S_GRAD;
                        end
                    end
                end
                
                // 3. Accumulate Squared Error
                S_ACCUM: begin
                    add_a <= loss_accum;
                    add_b <= mult_result; 
                    add_start <= 1;
                    if (add_done) begin
                        add_start <= 0;
                        loss_accum <= add_result;
                        idx <= idx + 1;
                        state <= S_SQUARE;
                    end
                end
                
                // 4. Compute Gradient: dL/dOutput = (Pred - Target)
                S_GRAD: begin
                    if (idx < OUTPUT_SIZE) begin
                        o_gradient[idx*DATA_WIDTH +: DATA_WIDTH] <= diff[idx];
                        idx <= idx + 1;
                    end else begin
                        state <= S_DONE;
                    end
                end
                
               
                S_DONE: begin
                    o_done <= 1;
                    if (!i_start) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule