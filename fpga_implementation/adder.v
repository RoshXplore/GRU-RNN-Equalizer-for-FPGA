`timescale 1ns / 1ps

module adder #(
    parameter DATA_WIDTH = 32
)(
    input clk,
    input rstn,
    input start,
    output reg done,
    input [DATA_WIDTH-1:0] value_in,
    input [DATA_WIDTH-1:0] bias,
    output reg [DATA_WIDTH-1:0] value_out
);

    // State machine for proper handshake
    localparam S_IDLE = 2'd0,
               S_WAIT_FPU = 2'd1,
               S_DONE = 2'd2;
    
    reg [1:0] state;
    reg fpu_start_pulse;
    
    // FPU signals
    wire [DATA_WIDTH-1:0] fpu_result;
    wire fpu_ready;
    wire ine, ovf, uf, div0, inf, zero, qnan, snan;
    
    // Instantiate FPU
    fpu u_fpu (
        .clk_i(clk),
        .rstn_i(rstn),
        .opa_i(value_in),
        .opb_i(bias),
        .fpu_op_i(3'b000), // ADD
        .rmode_i(2'b00),
        .start_i(fpu_start_pulse),  // Single-cycle pulse
        .output_o(fpu_result),
        .ready_o(fpu_ready),
        .ine_o(ine),
        .overflow_o(ovf),
        .underflow_o(uf),
        .div_zero_o(div0),
        .inf_o(inf),
        .zero_o(zero),
        .qnan_o(qnan),
        .snan_o(snan)
    );
    
    // FSM with proper handshaking
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            done <= 0;
            value_out <= 0;
            fpu_start_pulse <= 0;
        end else begin
            // Default: pulse is only 1 cycle
            fpu_start_pulse <= 0;
            
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                       
                        fpu_start_pulse <= 1;  // Generate single-cycle pulse
                        state <= S_WAIT_FPU;
                    end
                end
                
                S_WAIT_FPU: begin
                    if (fpu_ready) begin
                        value_out <= fpu_result;
                      
                        state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    done <= 1;
                    // Wait for start to drop before returning to IDLE
                    if (!start) begin
                       
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule