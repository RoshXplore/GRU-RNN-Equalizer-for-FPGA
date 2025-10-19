`timescale 1ns / 1ps

module tb_fpu_system;

    reg clk, rstn;
    reg adder_start, multiplier_start;
    wire adder_done, multiplier_done;

    parameter DATA_WIDTH = 32;

    reg [DATA_WIDTH-1:0] a_val, b_val;
    wire [DATA_WIDTH-1:0] add_out, mult_out;

    // --- Instantiate top system ---
    top_fpu_system uut (
        .clk(clk),
        .rstn(rstn),
        .a_val(a_val),
        .b_val(b_val),
        .add_out(add_out),
        .mult_out(mult_out),
        .adder_start(adder_start),
        .multiplier_start(multiplier_start),
        .adder_done(adder_done),
        .multiplier_done(multiplier_done)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk; // 100 MHz

    // Reset and test sequence
    initial begin
        rstn = 0;
        adder_start = 0;
        multiplier_start = 0;
        a_val = 0;
        b_val = 0;

        #20;
        rstn = 1;
        #10;
		  $stop;

        run_tests();
    end
	 
	 

    task run_tests;
        integer i;
        // Test vector inputs
        reg [31:0] test_a [0:12];
        reg [31:0] test_b [0:12];
        
        // FIX: Pre-calculated 32-bit "golden" results
        reg [31:0] expected_add [0:12];
        reg [31:0] expected_mult [0:12];
        
        begin
            $display("----- FPU Adder & Multiplier Test Started -----");
            
            // --- Initialize Test Vectors (Inputs) ---
            test_a[0] = 32'h3F800000; test_b[0] = 32'h3F800000; // 1.0, 1.0
            test_a[1] = 32'h40000000; test_b[1] = 32'h40000000; // 2.0, 2.0
            test_a[2] = 32'h40400000; test_b[2] = 32'h40400000; // 3.0, 3.0
            test_a[3] = 32'h40800000; test_b[3] = 32'hC0800000; // 4.0, -4.0
            test_a[4] = 32'hBF800000; test_b[4] = 32'h3F800000; // -1.0, 1.0
            test_a[5] = 32'h00000000; test_b[5] = 32'h00000000; // 0.0, 0.0
            test_a[6] = 32'h7F7FFFFF; test_b[6] = 32'h3F800000; // max_normal, 1.0
            test_a[7] = 32'h00800000; test_b[7] = 32'h00800000; // min_normal, min_normal
            test_a[8] = 32'h00400000; test_b[8] = 32'h00400000; // denormal, denormal
            test_a[9] = 32'h3F800000; test_b[9] = 32'h00000000; // 1.0, 0.0
            test_a[10]= 32'hBF800000; test_b[10]= 32'hBF800000; // -1.0, -1.0
            test_a[11]= 32'h7F800000; test_b[11]= 32'h3F800000; // +inf, 1.0
            test_a[12]= 32'hFF800000; test_b[12]= 32'hBF800000; // -inf, -1.0
            
            // --- Initialize Expected Results (Outputs) ---
            expected_add[0] = 32'h40000000; expected_mult[0] = 32'h3F800000; // 2.0, 1.0
            expected_add[1] = 32'h40800000; expected_mult[1] = 32'h40800000; // 4.0, 4.0
            expected_add[2] = 32'h40C00000; expected_mult[2] = 32'h41100000; // 6.0, 9.0
            expected_add[3] = 32'h00000000; expected_mult[3] = 32'hC1800000; // 0.0, -16.0
            expected_add[4] = 32'h00000000; expected_mult[4] = 32'hBF800000; // 0.0, -1.0
            expected_add[5] = 32'h00000000; expected_mult[5] = 32'h00000000; // 0.0, 0.0
            expected_add[6] = 32'h7F800000; expected_mult[6] = 32'h7F7FFFFF; // +inf, max_normal
            expected_add[7] = 32'h01000000; expected_mult[7] = 32'h00000000; // 2*min_normal, ~0
            expected_add[8] = 32'h00800000; expected_mult[8] = 32'h00000000; // min_normal, ~0
            expected_add[9] = 32'h3F800000; expected_mult[9] = 32'h00000000; // 1.0, 0.0
            expected_add[10]= 32'hC0000000; expected_mult[10]= 32'h3F800000; // -2.0, 1.0
            expected_add[11]= 32'h7F800000; expected_mult[11]= 32'h7F800000; // +inf, +inf
            expected_add[12]= 32'hFF800000; expected_mult[12]= 32'h7F800000; // -inf, +inf

            for(i=0; i<13; i=i+1) begin
                @(posedge clk);
                a_val = test_a[i];
                b_val = test_b[i];
                
                // --- Test Adder ---
                @(posedge clk);
                adder_start = 1;
                @(posedge clk);
                adder_start = 0;
                @(posedge adder_done);
                #1;
                $display("Adder: %h + %h = %h (expected %h)", 
                         a_val, b_val, add_out, expected_add[i]);

                // --- Test Multiplier ---
                @(posedge clk);
                multiplier_start = 1;
                @(posedge clk);
                multiplier_start = 0;
                @(posedge multiplier_done);
                #1;
                $display("Multiplier: %h * %h = %h (expected %h)", 
                         a_val, b_val, mult_out, expected_mult[i]);
            end

            $display("----- FPU Adder & Multiplier Test Completed -----");
            $stop;
        end
    endtask

endmodule