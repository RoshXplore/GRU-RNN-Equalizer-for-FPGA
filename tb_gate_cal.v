`timescale 1ns / 1ps

module tb_gate_cal;

    parameter DATA_WIDTH = 32;
    parameter GRU_UNITS = 7;
    parameter INPUT_FEATURES = 3;
    
    // DUT Signals
    reg clk, rstn;
    reg start_process;
    wire done_process;
    
    reg [DATA_WIDTH-1:0] i_data;
    reg [7:0] i_addr;
    reg i_we;
    reg i_activation_type;
    wire [DATA_WIDTH-1:0] o_result;

    // Test Data Arrays
    reg [DATA_WIDTH-1:0] input_vector  [0:INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] hidden_vector [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] W_weights     [0:INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] U_weights     [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bias_val;

    integer i;
    integer test_pass_count;
    integer test_fail_count;

    // DUT Instance
    gru_gate_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .GRU_UNITS(GRU_UNITS),
        .INPUT_FEATURES(INPUT_FEATURES)
    ) uut (
        .clk(clk),
        .rstn(rstn),
        .start_process(start_process),
        .done_process(done_process),
        .i_data(i_data),
        .i_addr(i_addr),
        .i_we(i_we),
        .i_activation_type(i_activation_type),
        .o_result(o_result)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;

    // Utility function to convert hex to real (for display)
    function real hex_to_real;
        input [31:0] hex_val;
        real result;
        begin
            result = $bitstoreal({32'b0, hex_val});
            hex_to_real = result;
        end
    endfunction

    // Improved data loading task
    task load_data_into_dut;
        begin
            @(posedge clk);
            i_we = 1'b1;

            // Load W weights
            for (i = 0; i < INPUT_FEATURES; i = i + 1) begin
                i_addr = 8'h00 + i;
                i_data = W_weights[i];
                @(posedge clk);
            end

            // Load U weights
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                i_addr = 8'h40 + i;
                i_data = U_weights[i];
                @(posedge clk);
            end

            // Load input vector
            for (i = 0; i < INPUT_FEATURES; i = i + 1) begin
                i_addr = 8'h80 + i;
                i_data = input_vector[i];
                @(posedge clk);
            end

            // Load hidden vector
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                i_addr = 8'hC0 + i;
                i_data = hidden_vector[i];
                @(posedge clk);
            end
            
            // Load bias
            i_addr = 8'hF0;
            i_data = bias_val;
            @(posedge clk);

            i_we = 1'b0;
            i_addr = 0;
            i_data = 0;
            
            repeat(5) @(posedge clk);
        end
    endtask

    // Verification task with tolerance
    task verify_result;
        input [DATA_WIDTH-1:0] expected;
        input [DATA_WIDTH-1:0] actual;
        input real tolerance_percent;
        input [200*8-1:0] test_name;
        
        real exp_val, act_val, error_percent;
        begin
            exp_val = hex_to_real(expected);
            act_val = hex_to_real(actual);
            
            if (exp_val != 0.0) begin
                error_percent = ((act_val - exp_val) / exp_val) * 100.0;
                if (error_percent < 0) error_percent = -error_percent;
            end else begin
                error_percent = (act_val != 0.0) ? 100.0 : 0.0;
            end
            
            $display("========================================");
            $display("Test: %s", test_name);
            $display("Expected: 0x%h (%.6f)", expected, exp_val);
            $display("Actual:   0x%h (%.6f)", actual, act_val);
            $display("Error:    %.3f%%", error_percent);
            
            if (error_percent <= tolerance_percent) begin
                $display("Status:   PASS");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("Status:   FAIL (exceeds %.1f%% tolerance)", tolerance_percent);
                test_fail_count = test_fail_count + 1;
            end
            $display("========================================\n");
        end
    endtask

    // Main test sequence
    initial begin
        // Initialize
        rstn = 0;
        start_process = 0;
        i_we = 0;
        i_addr = 0;
        i_data = 0;
        i_activation_type = 0;
        test_pass_count = 0;
        test_fail_count = 0;

        #20 rstn = 1;
        #10;
        
        $display("\n========================================");
        $display("GRU Gate Comprehensive Test Suite");
        $display("========================================\n");
        
        run_all_tests();
        
        #500;
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Tests Passed: %0d", test_pass_count);
        $display("Tests Failed: %0d", test_fail_count);
        $display("Total Tests:  %0d", test_pass_count + test_fail_count);
        $display("========================================\n");
        $stop;
    end

    task run_all_tests;
        begin
            test_simple_gate();
            test_with_bias();
            test_negative_values();
            test_zero_input();
            test_tanh_activation();
        end
    endtask

    task test_simple_gate;
        reg [DATA_WIDTH-1:0] expected_result;
        begin
            $display("\n=== Test 1: Simple Gate (Sigmoid) ===\n");
            
            input_vector[0] = 32'h3F800000; input_vector[1] = 32'h40000000; input_vector[2] = 32'h3F000000;
            hidden_vector[0] = 32'h3DCCCCCD; hidden_vector[1] = 32'h3E4CCCCD;
            for (i = 2; i < GRU_UNITS; i = i + 1) hidden_vector[i] = 0;
            W_weights[0] = 32'h3F800000; W_weights[1] = 32'h3F800000; W_weights[2] = 32'h3F800000;
            U_weights[0] = 32'h3F800000; U_weights[1] = 32'h3F800000;
            for (i = 2; i < GRU_UNITS; i = i + 1) U_weights[i] = 0;
            bias_val = 32'h00000000;
            i_activation_type = 0;
            expected_result = 32'h3F7A1CAC; // sigmoid(3.8) ≈ 0.978
            
            load_data_into_dut();
            
            @(posedge clk);
            start_process = 1;
            @(posedge clk);
            start_process = 0;
            
            wait(done_process);
            repeat(2) @(posedge clk);
            
            verify_result(expected_result, o_result, 2.0, "Simple Gate Sigmoid");
        end
    endtask

    task test_with_bias;
        reg [DATA_WIDTH-1:0] expected_result;
        begin
            $display("\n=== Test 2: With Bias ===\n");
            
            input_vector[0] = 32'h3F800000; input_vector[1] = 0; input_vector[2] = 0;
            hidden_vector[0] = 32'h3F800000;
            for (i = 1; i < GRU_UNITS; i = i + 1) hidden_vector[i] = 0;
            W_weights[0] = 32'h40000000; W_weights[1] = 0; W_weights[2] = 0;
            U_weights[0] = 32'h40400000;
            for (i = 1; i < GRU_UNITS; i = i + 1) U_weights[i] = 0;
            bias_val = 32'h3F800000;
            i_activation_type = 0;
            expected_result = 32'h3F7F8A23; // sigmoid(6.0) ≈ 0.9975

            load_data_into_dut();
            
            @(posedge clk);
            start_process = 1;
            @(posedge clk);
            start_process = 0;
            
            wait(done_process);
            repeat(2) @(posedge clk);
            
            verify_result(expected_result, o_result, 2.0, "Gate with Bias");
        end
    endtask

    task test_negative_values;
        reg [DATA_WIDTH-1:0] expected_result;
        begin
            $display("\n=== Test 3: Negative Values ===\n");
            
            input_vector[0] = 32'h3F800000; input_vector[1] = 32'hBF800000; input_vector[2] = 0;
            hidden_vector[0] = 32'h3F800000;
            for (i = 1; i < GRU_UNITS; i = i + 1) hidden_vector[i] = 0;
            W_weights[0] = 32'h3F800000; W_weights[1] = 32'h3F800000; W_weights[2] = 0;
            U_weights[0] = 32'h3F800000;
            for (i = 1; i < GRU_UNITS; i = i + 1) U_weights[i] = 0;
            bias_val = 32'h00000000;
            i_activation_type = 0;
            expected_result = 32'h3F3B67CF; // sigmoid(1.0) ≈ 0.731

            load_data_into_dut();
            
            @(posedge clk);
            start_process = 1;
            @(posedge clk);
            start_process = 0;
            
            wait(done_process);
            repeat(2) @(posedge clk);
            
            verify_result(expected_result, o_result, 2.0, "Negative Values");
        end
    endtask

    task test_zero_input;
        reg [DATA_WIDTH-1:0] expected_result;
        begin
            $display("\n=== Test 4: Zero Input ===\n");
            
            for (i = 0; i < INPUT_FEATURES; i = i + 1) input_vector[i] = 0;
            for (i = 0; i < GRU_UNITS; i = i + 1) hidden_vector[i] = 0;
            for (i = 0; i < INPUT_FEATURES; i = i + 1) W_weights[i] = 32'h3F800000;
            for (i = 0; i < GRU_UNITS; i = i + 1) U_weights[i] = 32'h3F800000;
            bias_val = 32'h00000000;
            i_activation_type = 0;
            expected_result = 32'h3F000000; // sigmoid(0) = 0.5

            load_data_into_dut();
            
            @(posedge clk);
            start_process = 1;
            @(posedge clk);
            start_process = 0;
            
            wait(done_process);
            repeat(2) @(posedge clk);
            
            verify_result(expected_result, o_result, 2.0, "Zero Input");
        end
    endtask

    task test_tanh_activation;
        reg [DATA_WIDTH-1:0] expected_result;
        begin
            $display("\n=== Test 5: Tanh Activation ===\n");
            
            input_vector[0] = 32'h3F800000; input_vector[1] = 0; input_vector[2] = 0;
            hidden_vector[0] = 32'h3F800000;
            for (i = 1; i < GRU_UNITS; i = i + 1) hidden_vector[i] = 0;
            W_weights[0] = 32'h3F800000; W_weights[1] = 0; W_weights[2] = 0;
            U_weights[0] = 32'h3F800000;
            for (i = 1; i < GRU_UNITS; i = i + 1) U_weights[i] = 0;
            bias_val = 32'h00000000;
            i_activation_type = 1; // Tanh
            expected_result = 32'h3F75DEC5; // tanh(2.0) ≈ 0.964

            load_data_into_dut();
            
            @(posedge clk);
            start_process = 1;
            @(posedge clk);
            start_process = 0;
            
            wait(done_process);
            repeat(2) @(posedge clk);
            
            verify_result(expected_result, o_result, 2.0, "Tanh Activation");
        end
    endtask
    
endmodule