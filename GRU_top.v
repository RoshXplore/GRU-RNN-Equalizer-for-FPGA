`timescale 1ns / 1ps

// ============================================================================
// GRU_top.v (Corrected and Completed for FPGA)
// ============================================================================
module GRU_top (
    input  wire CLOCK_50,    // 50 MHz clock from the FPGA
    input  wire [0:0] KEY,   // Pushbutton for reset (active low)
    input  wire UART_RXD,    // Serial input from laptop (unused here)
    output wire UART_TXD     // Serial output back to laptop (optional)
);
    // --- Clock and Reset ---
    wire rstn = KEY[0]; // Active high reset (button press is low)

    // --- Control Signals ---
    reg  start_model;
    wire model_done;

    // --- Data Wires ---
    wire [31:0] final_prediction;
    wire [(7*3*32)-1:0] wr_flat, wz_flat, wh_flat;
    wire [(7*7*32)-1:0] ur_flat, uz_flat, uh_flat;
    wire [(7*32)-1:0]   br_flat, bz_flat, bh_flat;
    wire [(7*32)-1:0]   fc_weights_flat;
    wire [31:0]        fc_bias;

    // --- Input Data Register ---
    // This register holds the 7 timesteps of input data for the GRU.
    reg [(7*3*32)-1:0] input_sequence_reg;

    // --- Module Instantiations ---
    // 1. Weights Loader (ROM)
    // This module should be created to load the pre-trained model weights.
    // For now, we assume it exists and provides the weights.
    weights_loader rom_loader (
        .o_Wr_flat(wr_flat), .o_Ur_flat(ur_flat), .o_br_flat(br_flat),
        .o_Wz_flat(wz_flat), .o_Uz_flat(uz_flat), .o_bz_flat(bz_flat),
        .o_Wh_flat(wh_flat), .o_Uh_flat(uh_flat), .o_bh_flat(bh_flat),
        .o_fc_weights_flat(fc_weights_flat),
        .o_fc_bias(fc_bias)
    );

    // 2. The main GRU Model you created
    GRU_Model gru_inst (
        .clk(CLOCK_50),
        .rstn(rstn),
        .i_start_model(start_model),
        .o_model_done(model_done),
        .i_input_sequence_flat(input_sequence_reg),
        .i_Wr_flat(wr_flat), .i_Ur_flat(ur_flat), .i_br_flat(br_flat),
        .i_Wz_flat(wz_flat), .i_Uz_flat(uz_flat), .i_bz_flat(bz_flat),
        .i_Wh_flat(wh_flat), .i_Uh_flat(uh_flat), .i_bh_flat(bh_flat),
        .i_fc_weights_flat(fc_weights_flat),
        .i_fc_bias(fc_bias),
        .o_final_prediction(final_prediction)
    );

    // --- Control Logic (Corrected) ---
    // This simple FSM will automatically start the model once reset is released.
    reg [1:0] state;
    localparam S_IDLE = 0, S_START = 1, S_WAIT = 2;

    always @(posedge CLOCK_50 or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            start_model <= 1'b0;
            // On reset, load a hardcoded input sequence for testing.
            // In a real application, this would come from sensors or UART.
            input_sequence_reg <= {21{32'h3f800000}}; // Example: Load sequence of all 1.0f
        end else begin
            // Default assignments
            start_model <= 1'b0;

            case(state)
                S_IDLE:
                    // After reset, move to start the model
                    state <= S_START;
                S_START: begin
                    // Pulse start high for one cycle
                    start_model <= 1'b1;
                    state <= S_WAIT;
                end
                S_WAIT:
                    // Wait here until the model is done, then go back to idle.
                    if (model_done)
                        state <= S_IDLE;
            endcase
        end
    end

    // Tie unused UART pin to idle high
    assign UART_TXD = 1'b1;

endmodule