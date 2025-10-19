`timescale 1ns / 1ps

module tb_GRU_Model;

    // Parameters
    parameter DATA_WIDTH = 32;
    parameter INPUT_FEATURES = 3;
    parameter GRU_UNITS = 3;
    parameter SEQUENCE_LENGTH = 3;
    parameter CLK_PERIOD = 10;
    parameter NUM_TEST_CASES = 8;

    // Clock and reset
    reg clk;
    reg rstn;
    
    // Control signals
    reg start_model;
    wire done_model;
    
    // Input sequence
    reg [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] input_sequence;
    
    // Output
    wire [DATA_WIDTH-1:0] prediction;
    
    // Test data memory
    reg [DATA_WIDTH-1:0] test_inputs [0:(NUM_TEST_CASES * SEQUENCE_LENGTH * INPUT_FEATURES) - 1];
    reg [DATA_WIDTH-1:0] expected_outputs [0:9];
    
    // Arrays to store final results
    real pred_floats [0:NUM_TEST_CASES-1];
    real exp_floats [0:NUM_TEST_CASES-1];
    real errors [0:NUM_TEST_CASES-1];
    reg passed [0:NUM_TEST_CASES-1];
    
    integer i, test_case, j, k;
    real pred_float, exp_float, error;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // DUT instantiation
    GRU_Model #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_FEATURES(INPUT_FEATURES),
        .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .i_start(start_model),
        .o_done(done_model),
        .i_sequence_flat(input_sequence),
        .o_prediction(prediction)
    );
    
    // Function to convert IEEE 754 to real
    function real bits_to_float;
        input [31:0] bits;
        integer sign;
        integer exponent;
        integer mantissa;
        real result;
        integer exp_signed;
        begin
            sign = bits[31];
            exponent = bits[30:23];
            mantissa = bits[22:0];

            if (exponent == 8'd255) begin
                if (mantissa == 0)
                    result = (sign ? -1.0/0.0 : 1.0/0.0);
                else
                    result = 0.0/0.0;
            end else if (exponent == 8'd0) begin
                exp_signed = 1 - 127;
                result = (mantissa / (2.0**23)) * (2.0 ** exp_signed);
                if (sign) result = -result;
            end else begin
                exp_signed = exponent - 127;
                result = (1.0 + (mantissa / (2.0**23))) * (2.0 ** exp_signed);
                if (sign) result = -result;
            end

            bits_to_float = result;
        end
    endfunction

    // Task to verify weight loading
    task verify_weight_loading;
        begin
            $display("\n========================================");
            $display("WEIGHT LOADING VERIFICATION");
            $display("========================================");
            
            // Check memory arrays
            $display("\n[TB] Wr_mem (Reset gate input weights) - First 9 values:");
            for (i = 0; i < 9; i = i + 1) begin
                $display("  Wr_mem[%0d] = %h (%f)", i, dut.Wr_mem[i], bits_to_float(dut.Wr_mem[i]));
            end
            
            $display("\n[TB] Expected W_ir values (ROW-MAJOR):");
            $display("  Row 0 (Cell[0]): [0.871984, 0.596488, 0.215018]");
            $display("  Row 1 (Cell[1]): [-2.807807, -0.426052, 0.159070]");
            $display("  Row 2 (Cell[2]): [-9.192985, -0.133023, -0.300217]");
            
            // Check Wr_flat distribution
            $display("\n[TB] Wr_flat register (should match Wr_mem):");
            for (i = 0; i < 9; i = i + 1) begin
                $display("  Wr_flat[%0d] = %h (%f)", i, 
                         dut.Wr_flat[i*DATA_WIDTH +: DATA_WIDTH],
                         bits_to_float(dut.Wr_flat[i*DATA_WIDTH +: DATA_WIDTH]));
            end
            
            // CRITICAL: Check how weights are distributed to each GRU cell
            $display("\n========================================");
            $display("CELL WEIGHT DISTRIBUTION CHECK");
            $display("========================================");
            
            // For each cell, show what weights it receives
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                $display("\n[TB] Cell[%0d] Reset Gate Weights (i_Wr_flat):", i);
                $display("  Should receive ROW %0d: indices [%0d, %0d, %0d]", 
                         i, i*INPUT_FEATURES, i*INPUT_FEATURES+1, i*INPUT_FEATURES+2);
                
                // Access the actual weights the cell sees
                // Adjust the hierarchical path based on your actual module structure:
                // Option 1: If cells are in an array
                // $display("  Wr[0] = %h", dut.gru_layer_inst.cells[i].i_Wr_flat[31:0]);
                
                // Option 2: If cells are generated with indices
                for (k = 0; k < INPUT_FEATURES; k = k + 1) begin
                    $display("  Weight[%0d] = %h (%f) - should be Wr_flat[%0d]",
                             k,
                             dut.Wr_flat[(i*INPUT_FEATURES + k)*DATA_WIDTH +: DATA_WIDTH],
                             bits_to_float(dut.Wr_flat[(i*INPUT_FEATURES + k)*DATA_WIDTH +: DATA_WIDTH]),
                             i*INPUT_FEATURES + k);
                end
            end
            
            $display("\n========================================\n");
        end
    endtask

    // Task to verify input distribution
    task verify_input_distribution;
        input integer timestep;
        begin
            $display("\n[TB] Input Distribution Verification (Timestep %0d):", timestep);
            $display("  Input sequence for this timestep:");
            
            for (i = 0; i < INPUT_FEATURES; i = i + 1) begin
                $display("    x[%0d] = %h (%f)", i,
                         input_sequence[(timestep*INPUT_FEATURES + i)*DATA_WIDTH +: DATA_WIDTH],
                         bits_to_float(input_sequence[(timestep*INPUT_FEATURES + i)*DATA_WIDTH +: DATA_WIDTH]));
            end
            
            $display("  Each Cell[j] should see ALL input features x[0:2]");
            $display("  NOT strided access like x[j], x[j+3], x[j+6]!");
        end
    endtask

    // Task to manually compute expected reset gate
    task compute_expected_reset_gate;
        input integer cell_idx;
        input integer timestep;
        real w0, w1, w2;
        real x0, x1, x2;
        real h0, h1, h2;
        real u0, u1, u2;
        real b_r;
        real sum_wx, sum_uh, preactivation, result;
        begin
            // Get weights for this cell (row cell_idx)
            w0 = bits_to_float(dut.Wr_flat[(cell_idx*INPUT_FEATURES + 0)*DATA_WIDTH +: DATA_WIDTH]);
            w1 = bits_to_float(dut.Wr_flat[(cell_idx*INPUT_FEATURES + 1)*DATA_WIDTH +: DATA_WIDTH]);
            w2 = bits_to_float(dut.Wr_flat[(cell_idx*INPUT_FEATURES + 2)*DATA_WIDTH +: DATA_WIDTH]);
            
            // Get inputs for this timestep
            x0 = bits_to_float(input_sequence[(timestep*INPUT_FEATURES + 0)*DATA_WIDTH +: DATA_WIDTH]);
            x1 = bits_to_float(input_sequence[(timestep*INPUT_FEATURES + 1)*DATA_WIDTH +: DATA_WIDTH]);
            x2 = bits_to_float(input_sequence[(timestep*INPUT_FEATURES + 2)*DATA_WIDTH +: DATA_WIDTH]);
            
            // Get hidden state (previous timestep)
            h0 = bits_to_float(dut.hidden_state[(0)*DATA_WIDTH +: DATA_WIDTH]);
            h1 = bits_to_float(dut.hidden_state[(1)*DATA_WIDTH +: DATA_WIDTH]);
            h2 = bits_to_float(dut.hidden_state[(2)*DATA_WIDTH +: DATA_WIDTH]);
            
            // Get U_hr weights (would need similar access)
            // For now, we'll just compute the W*x part
            
            sum_wx = w0*x0 + w1*x1 + w2*x2;
            
            $display("\n[TB] Manual Computation for Cell[%0d], Timestep %0d:", cell_idx, timestep);
            $display("  Weights: [%f, %f, %f]", w0, w1, w2);
            $display("  Inputs:  [%f, %f, %f]", x0, x1, x2);
            $display("  W*x = %f*%f + %f*%f + %f*%f = %f", 
                     w0, x0, w1, x1, w2, x2, sum_wx);
            $display("  (Add U*h and bias to complete calculation)");
        end
    endtask

    // Task to load and display test input sequence
    task load_test_sequence;
        input integer test_num;
        integer idx, base_idx;
        begin
            $readmemh("test_data/test_input.mem", test_inputs); 
            base_idx = test_num * SEQUENCE_LENGTH * INPUT_FEATURES;
            
            $display("[TB] Loading test sequence %0d:", test_num);
            
            input_sequence = 0;
            
            for (idx = 0; idx < SEQUENCE_LENGTH * INPUT_FEATURES; idx = idx + 1) begin
                input_sequence[idx*DATA_WIDTH +: DATA_WIDTH] = test_inputs[base_idx + idx];
                $display("  input[%0d] = %h (%f)", idx, 
                         test_inputs[base_idx + idx],
                         bits_to_float(test_inputs[base_idx + idx]));
            end
            
            $display("[TB] Verifying loaded sequence:");
            for (idx = 0; idx < SEQUENCE_LENGTH * INPUT_FEATURES; idx = idx + 1) begin
                $display("  sequence_flat[%0d] = %h", idx, 
                         input_sequence[idx*DATA_WIDTH +: DATA_WIDTH]);
            end
        end
    endtask

    // Task to run one test case with proper handshaking
    task run_test_case;
        input integer test_num;
        begin
            $display("\n========================================");
            $display("[TB] Starting Test Case %0d", test_num);
            $display("========================================");
            
            load_test_sequence(test_num);
            
            $display("[TB] Expected output: %h (%f)", 
                     expected_outputs[test_num],
                     bits_to_float(expected_outputs[test_num]));
            
            // Verify input distribution for timestep 0
            verify_input_distribution(0);
            
            // Compute expected value manually
            compute_expected_reset_gate(0, 0);
            
            repeat(5) @(posedge clk);
            
            @(posedge clk);
            start_model = 1;
            $display("[TB] Asserted start_model at time %0t", $time);
            
            @(posedge clk);
            start_model = 0;
            $display("[TB] De-asserted start_model at time %0t", $time);
            
            wait(done_model);
            $display("[TB] Detected done_model=1 at time %0t", $time);
            
            @(posedge clk);
            pred_floats[test_num] = bits_to_float(prediction);
            exp_floats[test_num] = bits_to_float(expected_outputs[test_num]);
            errors[test_num] = $sqrt((pred_floats[test_num] - exp_floats[test_num])**2);
            passed[test_num] = (errors[test_num] < 0.01);
            
            $display("[TB] Prediction = %h (%f)", prediction, pred_floats[test_num]);
            $display("[TB] Expected   = %h (%f)", expected_outputs[test_num], exp_floats[test_num]);
            $display("[TB] Error      = %f", errors[test_num]);
            
            $display("[TB] Final hidden state:");
            for (j = 0; j < GRU_UNITS; j = j + 1) begin
                $display("  h[%0d] = %h (%f)", j,
                         dut.hidden_state[j*DATA_WIDTH +: DATA_WIDTH],
                         bits_to_float(dut.hidden_state[j*DATA_WIDTH +: DATA_WIDTH]));
            end
            
            wait(!done_model);
            $display("[TB] Detected done_model=0 at time %0t", $time);
            
            repeat(5) @(posedge clk);
            
            $display("[TB] Test Case %0d Complete\n", test_num);
        end
    endtask

    // Main test sequence
    initial begin
        rstn = 0;
        start_model = 0;
        input_sequence = 0;
        
        $dumpfile("gru_model.vcd");
        $dumpvars(0, tb_GRU_Model);
        
        $readmemh("test_data/test_output.mem", expected_outputs);
        
        $display("\n========================================");
        $display("GRU Model Testbench Starting");
        $display("========================================\n");

        #(CLK_PERIOD*5);
        @(posedge clk);
        rstn = 1;
        $display("[TB] Reset released at time %0t", $time);
        #(CLK_PERIOD*2);
        
        wait(dut.weights_loaded);
        $display("[TB] Weights loaded at time %0t", $time);
        
        // MOVED BEFORE $finish - THIS IS THE FIX!
        verify_weight_loading();
        
        #(CLK_PERIOD*5);
        
        // Run all test cases
        for (test_case = 0; test_case < NUM_TEST_CASES; test_case = test_case + 1) begin
            run_test_case(test_case);
        end
        
        // Print summary
        $display("\n========================================");
        $display("FINAL TEST RESULTS");
        $display("========================================");
        for (test_case = 0; test_case < NUM_TEST_CASES; test_case = test_case + 1) begin
            $display("Test Case %0d:", test_case);
            $display("  Prediction: %f", pred_floats[test_case]);
            $display("  Expected:   %f", exp_floats[test_case]);
            $display("  Error:      %f", errors[test_case]);
            if (passed[test_case])
                $display("  ✓ PASS");
            else
                $display("  ✗ FAIL");
            $display("----------------------------------------");
        end
        
        $display("\nAll tests completed at time %0t", $time);
        #(CLK_PERIOD*10);
        
        // Now finish
        $finish;
    end

    // Timeout watchdog
    initial begin
        #(CLK_PERIOD*100000);
        $display("ERROR: Simulation timeout at time %0t!", $time);
        $finish;
    end

endmodule