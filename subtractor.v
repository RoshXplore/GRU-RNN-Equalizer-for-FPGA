`timescale 1ns / 1ps

module subtractor #(
    parameter DATA_WIDTH = 32
)(
    input wire clk,
    input wire rstn,
    input wire start,
    output reg done,
    input wire [DATA_WIDTH-1:0] value_a,
    input wire [DATA_WIDTH-1:0] value_b,
    output reg [DATA_WIDTH-1:0] value_out
);
    localparam S_IDLE           = 3'd0,
               S_START_NEGATE   = 3'd1,
               S_WAIT_NEGATE    = 3'd2,
               S_WAIT_NEG_ACK   = 3'd3,
               S_START_ADD      = 3'd4,
               S_WAIT_ADD       = 3'd5,
               S_WAIT_ADD_ACK   = 3'd6,
               S_DONE           = 3'd7;
    
    reg [2:0] state;
    reg mult_start, add_start;
    wire mult_done, add_done;
    wire [DATA_WIDTH-1:0] mult_out, add_out;
    reg [DATA_WIDTH-1:0] mult_in1, mult_in2, add_in1, add_in2;
    reg [DATA_WIDTH-1:0] negated_b;
    
    // Multiplier to negate b: -1.0 * b
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) MUL (
        .clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done),
        .w(mult_in1), .x(mult_in2), .mult_result(mult_out)
    );
    
    // Adder to compute a + (-b)
    adder #(.DATA_WIDTH(DATA_WIDTH)) ADD (
        .clk(clk), .rstn(rstn), .start(add_start), .done(add_done),
        .value_in(add_in1), .bias(add_in2), .value_out(add_out)
    );
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            done <= 0;
            mult_start <= 0;
            add_start <= 0;
            value_out <= 0;
            negated_b <= 0;
            mult_in1 <= 0;
            mult_in2 <= 0;
            add_in1 <= 0;
            add_in2 <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    done <= 0;
                    mult_start <= 0;
                    add_start <= 0;
                    
                    if (start) begin
                        mult_in1 <= 32'hBF800000; // -1.0 in IEEE 754
                        mult_in2 <= value_b;
                        state <= S_START_NEGATE;
                    end
                end
                
                S_START_NEGATE: begin
                    mult_start <= 1;
                    state <= S_WAIT_NEGATE;
                end
                
                S_WAIT_NEGATE: begin
                    mult_start <= 1; // Keep start high
                    if (mult_done) begin
                        negated_b <= mult_out;
                        mult_start <= 0; // De-assert
                        state <= S_WAIT_NEG_ACK;
                    end
                end
                
                S_WAIT_NEG_ACK: begin
                    mult_start <= 0;
                    if (!mult_done) begin // Wait for multiplier to acknowledge
                        add_in1 <= value_a;
                        add_in2 <= negated_b;
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
                        value_out <= add_out;
                        add_start <= 0; // De-assert
                        state <= S_WAIT_ADD_ACK;
                    end
                end
                
                S_WAIT_ADD_ACK: begin
                    add_start <= 0;
                    if (!add_done) begin // Wait for adder to acknowledge
                        state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    done <= 1;
                    mult_start <= 0;
                    add_start <= 0;
                    
                    if (!start) begin // Wait for parent to drop start
                        done <= 0;
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule