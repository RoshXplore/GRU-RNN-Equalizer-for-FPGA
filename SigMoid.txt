`timescale 1ns / 1ps

module SigMoid (
    input clk,
    input rstn,
    input start,
    output reg done,
    input [31:0] mult_sum_in,
    output reg [31:0] neuron_out
);
    
    // ============================================================================
    // 12-BIT ADDRESSING - 4096 ENTRIES (4-bit exponent, 7-bit mantissa)
    // ============================================================================
    parameter ADDR_WIDTH = 12;  // 4096 entries
    reg [31:0] sigmoid_lut [0:(1<<ADDR_WIDTH)-1];
    
    initial begin
        $readmemh("sigmoid_lut.mem", sigmoid_lut);
    end
    
    // IEEE 754 fields
    wire        sign_bit = mult_sum_in[31];
    wire [7:0]  exp      = mult_sum_in[30:23];
    wire [22:0] mant     = mult_sum_in[22:0];
    
    // Address components (12-bit total)
    reg [ADDR_WIDTH-1:0] addr;      // 12 bits
    reg [10:0] addr_mag;            // 11 bits (4 exp + 7 mant)
    reg [7:0] exp_offset;
    reg [3:0] exp_bits;             // 4 bits for exponent (was 3)
    reg [6:0] mant_bits;            // 7 bits for mantissa
    
    // Combinational address calculation
    // exp_base = 115, covers range [2^-12, 2^3] = [0.000244, 8.0]
    always @(*) begin
        mant_bits = mant[22:16];  // Extract top 7 mantissa bits
        
        if (exp < 8'd115) begin
            // Input too small: map to minimum address
            exp_bits = 4'd0;
            addr_mag = 11'd0;
        end 
        else if (exp >= 8'd131) begin  // 115 + 16 = 131
            // Input too large: saturate at maximum address
            exp_bits = 4'd15;
            addr_mag = 11'd2047;  // (15 << 7) | 0x7F = 2047
        end 
        else begin
            // Normal range: 115 <= exp < 131
            exp_offset = exp - 8'd115;
            exp_bits = exp_offset[3:0];  // 4-bit exponent offset
            addr_mag = {exp_bits, mant_bits};  // 4 + 7 = 11 bits
        end
        
        addr = {sign_bit, addr_mag};  // 1 + 11 = 12 bits
    end
    
    // State machine
    reg [1:0] state;
    localparam S_IDLE = 2'd0, S_COMPUTE = 2'd1, S_DONE = 2'd2;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            done <= 1'b0;
            neuron_out <= 32'h00000000;
        end else begin
            done <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (start) state <= S_COMPUTE;
                end
                
                S_COMPUTE: begin
                    neuron_out <= sigmoid_lut[addr];
                    state <= S_DONE;
                end
                
                S_DONE: begin
                    done <= 1'b1;
                    if (!start) state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule