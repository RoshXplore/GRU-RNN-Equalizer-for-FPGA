`timescale 1ns / 1ps

module tb_gru_gate_level;

    parameter DATA_WIDTH      = 32;
    parameter INPUT_FEATURES  = 3;
    parameter GRU_UNITS       = 3;
    parameter SEQUENCE_LENGTH = 3;
    parameter CLK_PERIOD      = 20;
    parameter NUM_TEST_CASES  = 8;
    parameter TIMEOUT_VAL     = 500000;

    reg clk;
    reg rstn;
    reg btn_start;
    reg serial_data_in;
    reg serial_clk_in;
    reg serial_load_en;

    wire serial_data_out;
    wire serial_clk_out;
    wire serial_valid;
    wire led_done;
    wire led_ready;
    wire led_loading;
    wire [3:0] led_state;

    reg [DATA_WIDTH-1:0] test_inputs [0:(NUM_TEST_CASES * SEQUENCE_LENGTH * INPUT_FEATURES) - 1];
    reg [DATA_WIDTH-1:0] expected_outputs [0:NUM_TEST_CASES-1];

    real pred_floats [0:NUM_TEST_CASES-1];
    real exp_floats  [0:NUM_TEST_CASES-1];
    real errors      [0:NUM_TEST_CASES-1];
    reg  passed      [0:NUM_TEST_CASES-1];

    integer i, j, test_case, base_idx;
    reg [DATA_WIDTH-1:0] received_output;

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // DUT Instantiation
    GRU_Serial_Top dut (
        .clk(clk),
        .rstn(rstn),
        .btn_start(btn_start),
        .serial_data_in(serial_data_in),
        .serial_clk_in(serial_clk_in),
        .serial_load_en(serial_load_en),
        .serial_data_out(serial_data_out),
        .serial_clk_out(serial_clk_out),
        .serial_valid(serial_valid),
        .led_done(led_done),
        .led_ready(led_ready),
        .led_loading(led_loading),
        .led_state(led_state)
    );

    // State monitor
    reg [3:0] prev_state;
    always @(posedge clk) begin
        if (led_state !== prev_state) begin
            $display("[%0t] [DUT STATE CHANGE] %0d -> %0d (ready=%b loading=%b done=%b)", 
                     $time, prev_state, led_state, led_ready, led_loading, led_done);
            prev_state <= led_state;
        end
    end

    function real bits_to_float;
        input [31:0] bits;
        integer sign, exponent, mantissa, exp_signed;
        real result;
        begin
            sign     = bits[31];
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

    task send_serial_word;
        input [DATA_WIDTH-1:0] data;
        integer bit_idx;
        begin
            for (bit_idx = DATA_WIDTH-1; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                @(negedge clk);
                serial_data_in = data[bit_idx];
                serial_clk_in = 1;
                
                @(negedge clk);
                serial_clk_in = 0;
                
                @(negedge clk);
            end
            @(negedge clk);
            serial_clk_in = 0;
        end
    endtask

    task wait_with_timeout;
        input signal;
        input integer timeout_cycles;
        input [200:0] message;
        integer count;
        begin
            count = 0;
            
            repeat(3) @(posedge clk);
            
            if (signal) begin
                $display("[%0t] [TB] SUCCESS: %s (signal asserted)", $time, message);
            end else begin
                while (!signal && count < timeout_cycles) begin
                    @(posedge clk);
                    count = count + 1;
                    if (count % 10000 == 0) begin
                        $display("[%0t] [TB WAITING] %s - %0d cycles (state=%0d, signal=%b)", 
                                 $time, message, count, led_state, signal);
                    end
                end
                if (!signal) begin
                    $display("[%0t] [TB] TIMEOUT: %s (waited %0d cycles, final state=%0d)", 
                             $time, message, count, led_state);
                end else begin
                    $display("[%0t] [TB] SUCCESS: %s (after %0d cycles)", $time, message, count);
                end
            end
        end
    endtask

    task wait_for_ready_state;
        input integer timeout_cycles;
        input [200:0] message;
        integer count;
        begin
            count = 0;
            
            while (!(led_state == 4'd1 || led_state == 4'd3) && count < timeout_cycles) begin
                @(posedge clk);
                count = count + 1;
                if (count % 10000 == 0) begin
                    $display("[%0t] [TB WAITING] %s - %0d cycles (state=%0d)", 
                             $time, message, count, led_state);
                end
            end
            
            if (!(led_state == 4'd1 || led_state == 4'd3)) begin
                $display("[%0t] [TB] TIMEOUT: %s (waited %0d cycles, final state=%0d)", 
                         $time, message, count, led_state);
            end else begin
                $display("[%0t] [TB] SUCCESS: %s (after %0d cycles, state=%0d)", 
                         $time, message, count, led_state);
            end
        end
    endtask

    task receive_serial_output;
        output [DATA_WIDTH-1:0] data;
        integer bit_idx;
        integer timeout_counter;
        begin
            data = 0;
            timeout_counter = 0;
            
            $display("[%0t] [TB] Waiting for serial_valid...", $time);
            while (!serial_valid && timeout_counter < TIMEOUT_VAL) begin
                @(posedge clk);
                timeout_counter = timeout_counter + 1;
                if (timeout_counter % 10000 == 0) begin
                    $display("[%0t] [TB] Still waiting for serial_valid (state=%0d)...", 
                             $time, led_state);
                end
            end

            if (!serial_valid) begin
                $display("[%0t] [TB] ERROR: Timed out waiting for serial_valid", $time);
                data = 32'hDEADBEEF;
            end else begin
                $display("[%0t] [TB] serial_valid asserted. Receiving data.", $time);
                
                for (bit_idx = DATA_WIDTH-1; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                    @(posedge serial_clk_out); 
                    data[bit_idx] = serial_data_out;
                end
                
                $display("[%0t] [TB] Received: %h (%f)", 
                         $time, data, bits_to_float(data));
            end
        end
    endtask

    task load_test_sequence_serial;
        input integer test_num;
        integer idx, seq_idx;
        begin
            base_idx = test_num * SEQUENCE_LENGTH * INPUT_FEATURES;
            $display("[%0t] [TB] Loading test sequence %0d (9 words)", $time, test_num);

            @(posedge clk);
            serial_load_en = 1;
            
            repeat(5) @(posedge clk);
            
            for (idx = 0; idx < SEQUENCE_LENGTH * INPUT_FEATURES; idx = idx + 1) begin
                seq_idx = base_idx + idx;
                $display("[%0t] [TB] Sending word %0d: %h (%f)", 
                         $time, idx, test_inputs[seq_idx], bits_to_float(test_inputs[seq_idx]));
                send_serial_word(test_inputs[seq_idx]);
                
                repeat(10) @(posedge clk);
            end

            repeat(20) @(posedge clk);
            
            serial_load_en = 0;
            $display("[%0t] [TB] Serial load_en deasserted, waiting for DUT to process", $time);
            
            repeat(50) @(posedge clk);
        end
    endtask

    task run_test_case;
        input integer test_num;
        real pred_val, exp_val, err;
        begin
            $display("\n========================================");
            $display("[TB] Test Case %0d", test_num);
            $display("========================================");

            $display("[%0t] [TB] Waiting for DUT ready state (current state=%0d)...", 
                     $time, led_state);
            wait_for_ready_state(TIMEOUT_VAL, "Waiting for DUT ready state before load");
            
            if (!(led_state == 4'd1 || led_state == 4'd3)) begin
                $display("[%0t] [TB] ERROR: DUT not in ready state", $time);
                passed[test_num] = 0;
                pred_floats[test_num] = 0.0;
                exp_floats[test_num] = 0.0;
                errors[test_num] = 999.0;
            end else begin
                $display("[%0t] [TB] DUT is in ready state, proceeding with load", $time);
                load_test_sequence_serial(test_num);

                $display("[%0t] [TB] Load complete, waiting for READY state again (current state=%0d)", 
                         $time, led_state);
                wait_for_ready_state(TIMEOUT_VAL, "Waiting for DUT ready state after load");
                
                if (!(led_state == 4'd3)) begin
                    $display("[%0t] [TB] ERROR: DUT not in READY state after load (state=%0d)", 
                             $time, led_state);
                    passed[test_num] = 0;
                    pred_floats[test_num] = 0.0;
                    exp_floats[test_num] = 0.0;
                    errors[test_num] = 999.0;
                end else begin
                    repeat(10) @(posedge clk);
                    btn_start = 1;
                    $display("[%0t] [TB] Start button pressed", $time);
                    
                    repeat(5) @(posedge clk);
                    btn_start = 0;
                    $display("[%0t] [TB] Start button released", $time);

                    receive_serial_output(received_output);
                    
                    $display("[%0t] [TB] Checking for led_done immediately after serial reception", $time);
                    
                    repeat(5) @(posedge clk);
                    
                    if (led_done) begin
                        $display("[%0t] [TB] SUCCESS: led_done detected", $time);
                    end else begin
                        $display("[%0t] [TB] WARNING: led_done not yet asserted, waiting...", $time);
                        wait_with_timeout(led_done, 1000, "Waiting for led_done (late check)");
                    end

                    pred_val = bits_to_float(received_output);
                    exp_val  = bits_to_float(expected_outputs[test_num]);
                    err      = (pred_val - exp_val);
                    if (err < 0) err = -err;

                    pred_floats[test_num] = pred_val;
                    exp_floats[test_num]  = exp_val;
                    errors[test_num]      = err;
                    passed[test_num]      = (err < 0.01);

                    $display("[TB] Prediction = %f, Expected = %f, Error = %f, Result = %s",
                             pred_val, exp_val, err, passed[test_num] ? "PASS" : "FAIL");
                end
            end
                     
            repeat(20) @(posedge clk);
        end
    endtask

    initial begin
        rstn = 0;
        btn_start = 0;
        serial_data_in = 0;
        serial_clk_in = 0;
        serial_load_en = 0;
        prev_state = 4'hF;

        $readmemh("test_data/test_input.mem", test_inputs);
        $readmemh("test_data/test_output.mem", expected_outputs);

        $display("\n========================================");
        $display("GRU Gate-Level Testbench Starting");
        $display("========================================\n");

        repeat(20) @(posedge clk);
        rstn = 1;
        $display("[%0t] [TB] Reset released", $time);

        repeat(100) @(posedge clk);
        $display("[%0t] [TB] Initial settling complete, starting tests", $time);

        for (test_case = 0; test_case < NUM_TEST_CASES; test_case = test_case + 1)
            run_test_case(test_case);

        j = 0;
        for (test_case = 0; test_case < NUM_TEST_CASES; test_case = test_case + 1)
            if (passed[test_case]) j = j + 1;

        $display("\n========================================");
        $display("SIMULATION SUMMARY");
        $display("========================================");
        for (test_case = 0; test_case < NUM_TEST_CASES; test_case = test_case + 1) begin
            $display("Test %0d: Pred=%f Exp=%f Err=%f %s", 
                     test_case, 
                     pred_floats[test_case],
                     exp_floats[test_case],
                     errors[test_case],
                     passed[test_case] ? "PASS" : "FAIL");
        end
        $display("========================================");
        $display("Passed: %0d / %0d", j, NUM_TEST_CASES);
        $display("========================================");
        
        repeat(50) @(posedge clk);
        $finish;
    end
endmodule