`timescale 1ns / 1ps

module tb_fpga_top;

    // ========================================================================
    // 1. PARAMETERS (Must match fpga_top_module)
    // ========================================================================
    parameter DATA_WIDTH = 32;
    parameter INPUT_FEATURES = 2;
    parameter GRU_UNITS = 2;      // Note: Your provided code uses 2 units
    parameter SEQUENCE_LENGTH = 3;
    parameter OUTPUT_SIZE = 2;

    // ========================================================================
    // 2. SIGNALS
    // ========================================================================
    reg MAX10_CLK1_50;
    reg [1:0] KEY;
    reg [9:0] SW;
    
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    // ========================================================================
    // 3. DUT INSTANTIATION
    // ========================================================================
    fpga_top_module #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_FEATURES(INPUT_FEATURES),
        .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH),
        .OUTPUT_SIZE(OUTPUT_SIZE)
    ) dut (
        .MAX10_CLK1_50(MAX10_CLK1_50),
        .KEY(KEY),
        .SW(SW),
        .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), 
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    // ========================================================================
    // 4. CLOCK GENERATION (50 MHz -> 20ns Period)
    // ========================================================================
    always #10 MAX10_CLK1_50 = ~MAX10_CLK1_50;

    // ========================================================================
    // 5. HELPER FUNCTIONS (For printing floats)
    // ========================================================================
    function real hex2real;
        input [31:0] hex;
        begin
            hex2real = $bitstoshortreal(hex);
        end
    endfunction

    // ========================================================================
    // 6. MAIN STIMULUS
    // ========================================================================
    initial begin
        // Initialize Signals
        MAX10_CLK1_50 = 0;
        KEY = 2'b11; // Keys are Active Low (1 = Not Pressed)
        SW = 10'b0;  // Switches Low
        
        $display("\n===========================================================");
        $display("TEST: FPGA Top Level (Synthesizable Wrapper)");
        $display("===========================================================");
        
        // 1. Reset Sequence (Active Low)
        $display("[%0t] Resetting...", $time);
        KEY[0] = 0; // Press Reset
        #200;
        KEY[0] = 1; // Release Reset
        #100;
        
        // 2. Start Training
        $display("[%0t] Toggling Start Switch (SW[0])...", $time);
        SW[0] = 1; // Flip Switch High
        // Note: The FSM inside detects the rising edge of SW[0]
        
        // 3. Wait for Completion
        // Since we can't see o_done on a pin, we wait for the internal state 
        // to reach FSM_DONE or a timeout.
        wait(dut.state == 5); // Wait for FSM_DONE state (5)
        
        $display("\n===========================================================");
        $display("SUCCESS: FPGA Logic Reached DONE State");
        $display("===========================================================");
        $finish;
    end

    // ========================================================================
    // 7. MONITORING (Peeking inside the chip)
    // ========================================================================
    // Since the top module doesn't output the loss directly (it goes to HEX),
    // we use hierarchical references to print status updates to the console.
    
    integer last_epoch = -1;
    
    always @(posedge MAX10_CLK1_50) begin
        // Detect Epoch Change inside the DUT
        if (dut.epoch != last_epoch) begin
            $display("  >> Epoch %0d Started...", dut.epoch + 1);
            last_epoch = dut.epoch;
        end
        
        // Optional: Print Loss every time a sample finishes training
        // We look for the trainer's done signal inside the top module
        if (dut.o_training_done) begin
            // Only print periodically to avoid spamming console
            if (dut.s_idx % 500 == 0) begin
                 $display("     [Sample %0d] Loss: %f", dut.s_idx, hex2real(dut.o_current_loss));
            end
        end
    end

    // ========================================================================
    // 8. TIMEOUT GUARD
    // ========================================================================
    initial begin
        #2000000000; // 2 seconds sim time
        $display("\n[ERROR] Simulation Timeout! Logic stuck.");
        $finish;
    end

endmodule