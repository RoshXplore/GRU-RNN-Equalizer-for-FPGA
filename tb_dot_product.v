`timescale 1ns / 1ps
module tb_dot_product;
    parameter DATA_WIDTH = 32;
    parameter MAX_VECTOR_SIZE = 7;
    
    reg clk, rstn;
    reg [DATA_WIDTH-1:0] data_in;
    reg [2:0] write_addr;
    reg write_en_a, write_en_b;
    reg start_calc;
    reg [3:0] vector_length;
    wire calc_done;
    wire [DATA_WIDTH-1:0] result;
    
    // Instantiate the top-level module
    dot_product_top #(.DATA_WIDTH(DATA_WIDTH), .MAX_VECTOR_SIZE(MAX_VECTOR_SIZE)) uut (
        .clk(clk),
        .rstn(rstn),
        .data_in(data_in),
        .write_addr(write_addr),
        .write_en_a(write_en_a),
        .write_en_b(write_en_b),
        .start_calc(start_calc),
        .vector_length(vector_length),
        .calc_done(calc_done),
        .result(result)
    );
    
    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;
    
    // Test vectors
    reg [DATA_WIDTH-1:0] test_vec_a [0:MAX_VECTOR_SIZE-1];
    reg [DATA_WIDTH-1:0] test_vec_b [0:MAX_VECTOR_SIZE-1];
    
    // Monitor internal signals for debugging
    initial begin
        $monitor("Time=%0t state=%0d index=%0d partial_sum=%h result=%h mult_done=%b add_done=%b", 
                 $time, 
                 uut.u_dot_product_core.state,
                 uut.u_dot_product_core.index,
                 uut.u_dot_product_core.partial_sum,
                 uut.u_dot_product_core.result,
                 uut.u_dot_product_core.mult_done,
                 uut.u_dot_product_core.add_done);
    end
    
    initial begin
        rstn = 0; #20;
        rstn = 1; #10;
        run_tests();
        #500 $stop;
    end
    
    task run_tests;
        begin
            $display("----- Dot Product Test Started -----");
            
            // Test 1: A = [1,2], B = [3,4]
            // Expected: 1*3 + 2*4 = 3 + 8 = 11 = 0x41300000
            test_vec_a[0] = 32'h3F800000; // 1.0
            test_vec_a[1] = 32'h40000000; // 2.0
            test_vec_b[0] = 32'h40400000; // 3.0
            test_vec_b[1] = 32'h40800000; // 4.0
            run_single_test(2, 32'h41300000);
            
            // Test 2: A = [2,-4,3], B = [5,1,2]
            // Expected: 2*5 + (-4)*1 + 3*2 = 10 - 4 + 6 = 12 = 0x41400000
            test_vec_a[0] = 32'h40000000; // 2.0
            test_vec_a[1] = 32'hC0800000; // -4.0
            test_vec_a[2] = 32'h40400000; // 3.0
            test_vec_b[0] = 32'h40A00000; // 5.0
            test_vec_b[1] = 32'h3F800000; // 1.0
            test_vec_b[2] = 32'h40000000; // 2.0
            run_single_test(3, 32'h41400000);
            
            $display("----- Dot Product Test Completed -----");
        end
    endtask
    
    // Helper to run one test
    task run_single_test(input [3:0] len, input [31:0] expected);
        integer i;
        begin
            $display("\n--- New Test (length=%0d) ---", len);
            $display("Loading vectors...");
            
            for (i=0; i<len; i=i+1) begin
                @(posedge clk);
                write_addr = i;
                data_in = test_vec_a[i];
                write_en_a = 1; write_en_b = 0;
                $display("Writing A[%0d] = %h", i, test_vec_a[i]);
                
                @(posedge clk);
                write_en_a = 0;
                data_in = test_vec_b[i];
                write_en_b = 1;
                $display("Writing B[%0d] = %h", i, test_vec_b[i]);
                
                @(posedge clk);
                write_en_b = 0;
            end
            
            $display("Starting calculation...");
            @(posedge clk);
            vector_length = len;
            start_calc = 1;
            @(posedge clk);
            start_calc = 0;
            
            wait(calc_done);
            @(posedge clk); // let result settle
            
            $display("\nTest Result = %h (Expected = %h)", result, expected);
            if(result == expected) 
                $display(">>> PASS <<<");
            else 
                $display(">>> FAIL <<<");
        end
    endtask
endmodule