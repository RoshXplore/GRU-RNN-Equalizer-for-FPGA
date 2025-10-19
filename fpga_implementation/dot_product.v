`timescale 1ns / 1ps

module dot_product #(
    parameter DATA_WIDTH = 32,
    parameter MAX_VECTOR_SIZE = 7
)(
    input clk,
    input rstn,
    input start,
    output reg done,
    input [DATA_WIDTH*MAX_VECTOR_SIZE-1:0] vector_a_flat,
    input [DATA_WIDTH*MAX_VECTOR_SIZE-1:0] vector_b_flat,
    input [3:0] vector_length,
    output reg [DATA_WIDTH-1:0] result
);
    // --- Internal signals ---
    reg [2:0] index;
    reg [DATA_WIDTH-1:0] current_a, current_b;
    reg [DATA_WIDTH-1:0] partial_sum;
    reg mult_start, add_start;
    wire mult_done, add_done;
    wire [DATA_WIDTH-1:0] mult_out;
    wire [DATA_WIDTH-1:0] add_out;
    
    // --- Sub-module Instantiations ---
    multiplier u_mult (
        .clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done),
        .w(current_a), .x(current_b), .mult_result(mult_out)
    );
    
    adder u_add (
        .clk(clk), .rstn(rstn), .start(add_start), .done(add_done),
        .value_in(mult_out), .bias(partial_sum), .value_out(add_out)
    );
    
    // --- FSM States ---
    localparam S_IDLE          = 4'd0,
               S_LOAD          = 4'd1,
               S_START_MULT    = 4'd2,
               S_WAIT_MULT     = 4'd3,
               S_WAIT_MULT_ACK = 4'd4,
               S_START_ADD     = 4'd5,
               S_WAIT_ADD      = 4'd6,
               S_WAIT_ADD_ACK  = 4'd7,
               S_DONE          = 4'd8;
    
    reg [3:0] state;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            index <= 0;
            partial_sum <= 0;
            result <= 0;
            current_a <= 0;
            current_b <= 0;
            mult_start <= 0;
            add_start <= 0;
            done <= 0;
        end else begin
            // Default signals
            done <= 0;
            
            case(state)
                S_IDLE: begin
                    mult_start <= 0;
                    add_start <= 0;
                    if (start) begin
                        
                        index <= 0;
                        partial_sum <= 0;
                        result <= 0;
                        state <= S_LOAD;
                    end
                end
                
                S_LOAD: begin
                    // Load current vector elements
                    current_a <= vector_a_flat[DATA_WIDTH*index +: DATA_WIDTH];
                    current_b <= vector_b_flat[DATA_WIDTH*index +: DATA_WIDTH];
                   
                    state <= S_START_MULT;
                end
                
                S_START_MULT: begin
                    mult_start <= 1;
                    state <= S_WAIT_MULT;
                end
                
                S_WAIT_MULT: begin
                    mult_start <= 1; // Keep start high
                    if (mult_done) begin
                        
                        mult_start <= 0; // De-assert
                        state <= S_WAIT_MULT_ACK;
                    end
                end
                
                S_WAIT_MULT_ACK: begin
                    mult_start <= 0;
                    if (!mult_done) begin // Wait for multiplier to return to idle
                        state <= S_START_ADD;
                    end
                end
                
                S_START_ADD: begin
                    add_start <= 1;
                    state <= S_WAIT_ADD;
                end
                
                S_WAIT_ADD: begin
                    add_start <= 1; // Keep start high
                    if (add_done) begin
                      
                        // Update partial sum with the result
                        partial_sum <= add_out;
                        add_start <= 0; // De-assert
                        state <= S_WAIT_ADD_ACK;
                    end
                end
                
                S_WAIT_ADD_ACK: begin
                    add_start <= 0;
                    if (!add_done) begin // Wait for adder to return to idle
                        // Check if this is the last element
                        if (index == vector_length - 1) begin
                            result <= partial_sum;  // Store final result
                          
                            state <= S_DONE;
                        end else begin
                            index <= index + 1;
                            state <= S_LOAD;
                        end
                    end
                end
                
                S_DONE: begin
                    done <= 1;
                    if (!start) begin
                    
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule