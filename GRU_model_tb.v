`timescale 1ns / 1ps

module GRU_model_tb;

    // --- Testbench Parameters ---
    localparam CLOCK_PERIOD = 20; // 50 MHz clock

    // --- DUT Connections ---
    reg  CLOCK_50 = 1'b0;
    reg  [0:0] KEY; // This is the main input we will control
    reg  UART_RXD = 1'b1;
    wire UART_TXD;
    wire model_done;
    wire [31:0] final_prediction;

    // --- Instantiate the Device Under Test (DUT) ---
    GRU_top dut (
        .CLOCK_50(CLOCK_50),
        .KEY(KEY),
        .UART_RXD(UART_RXD),
        .UART_TXD(UART_TXD)
        // Note: We can monitor internal signals, but we should not drive them.
        // We will monitor the top-level outputs instead.
    );

    // Access internal signals for monitoring purposes
    // These aliases make the wait statement cleaner
    assign model_done = dut.model_done;
    assign final_prediction = dut.final_prediction;

    // --- Clock Generator ---
    always #(CLOCK_PERIOD / 2) CLOCK_50 = ~CLOCK_50;

    // --- Test Sequence ---
    initial begin
        $display("========================================");
        $display("=== GRU Model Testbench Initializing ===");
        $display("========================================");

        // 1. Initialize and apply reset
        KEY = 1'b1; // Reset is active-low, so start with it de-asserted
        #100;

        $display("[%0t ns] Applying reset (pressing KEY0)...", $time);
        KEY = 1'b0; // Assert reset
        #(CLOCK_PERIOD * 10);

        KEY = 1'b1; // De-assert reset
        $display("[%0t ns] Reset released. Model should start automatically.", $time);
        
        // The GRU_top module's internal FSM will now start the model.
        // We do not need to drive `start_model` from the testbench.
        // The DUT will also load its own hardcoded input sequence on reset.

        // 2. Wait for the model to complete
        $display("[%0t ns] Waiting for model to complete...", $time);
        wait (model_done == 1'b1);

        // 3. Report Success
        $display("[%0t ns] ✅ SUCCESS: Model reported done!", $time);
        $display("      Final prediction: 0x%h", final_prediction);
        #(CLOCK_PERIOD * 5);

        $finish;
    end

    // --- Timeout Condition ---
    initial begin
        #20_000_000; // 20ms timeout, a very generous limit
        $display("[%0t ns] ❌ TIMEOUT: Simulation ran for 20ms without completion.", $time);
        $display("      Final state of GRU_Model FSM: %d", dut.gru_inst.state);
        $display("      Final timestep: %d", dut.gru_inst.timestep_counter);
        $finish;
    end

endmodule
