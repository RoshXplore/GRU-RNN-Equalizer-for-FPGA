`timescale 1ns / 1ps

module weight_updater_single #(
    parameter DATA_WIDTH = 32
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_start,
    output reg  o_done,
    
    input  wire [DATA_WIDTH-1:0] i_learning_rate,
    input  wire [DATA_WIDTH-1:0] i_current_weight,
    input  wire [DATA_WIDTH-1:0] i_current_gradient,
    
    output reg [DATA_WIDTH-1:0] o_new_weight
);

    localparam S_IDLE       = 0, 
               S_MUL_START  = 1, S_MUL_WAIT = 2, S_MUL_ACK = 3,
               S_SUB_START  = 4, S_SUB_WAIT = 5, S_SUB_ACK = 6,
               S_DONE       = 7;
               
    reg [2:0] state;
    
    reg mul_start, sub_start;
    wire mul_done, sub_done;
    wire [DATA_WIDTH-1:0] mul_res, sub_res;
    
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) u_mul (
        .clk(clk), .rstn(rstn), .start(mul_start), .done(mul_done), 
        .w(i_learning_rate), .x(i_current_gradient), .mult_result(mul_res)
    );
    subtractor #(.DATA_WIDTH(DATA_WIDTH)) u_sub (
        .clk(clk), .rstn(rstn), .start(sub_start), .done(sub_done), 
        .value_a(i_current_weight), .value_b(mul_res), .value_out(sub_res)
    );

    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            state <= S_IDLE; o_done <= 0; o_new_weight <= 0;
            mul_start <= 0; sub_start <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    o_done <= 0;
                    if(i_start) state <= S_MUL_START;
                end
                
                // 1. Multiplication: LR * Grad
                S_MUL_START: begin
                    mul_start <= 1; 
                    state <= S_MUL_WAIT;
                end
                S_MUL_WAIT: begin
                    if(mul_done) begin
                        mul_start <= 0;
                        state <= S_MUL_ACK;
                    end
                end
                S_MUL_ACK: begin
                    
                    if(!mul_done) state <= S_SUB_START;
                end
                
                // 2. Subtraction: Weight - Result
                S_SUB_START: begin
                    sub_start <= 1;
                    state <= S_SUB_WAIT;
                end
                S_SUB_WAIT: begin
                    if(sub_done) begin
                        o_new_weight <= sub_res;
                        sub_start <= 0; 
                        state <= S_SUB_ACK;
                    end
                end
                S_SUB_ACK: begin
                    
                    if(!sub_done) state <= S_DONE;
                end
                
                // 3. Finish
                S_DONE: begin
                    o_done <= 1;
                    
                    if(!i_start) begin
                        o_done <= 0;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule