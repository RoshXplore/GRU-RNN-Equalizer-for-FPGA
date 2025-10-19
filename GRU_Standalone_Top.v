`timescale 1ns / 1ps

// Simplified GRU Test Module for DE10-Lite
// Easy visual verification with LEDs and 7-segment displays
module GRU_Standalone_Top #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 3,
    parameter GRU_UNITS = 3,
    parameter SEQUENCE_LENGTH = 3,
    parameter NUM_TEST_CASES = 8
)(
    input wire clk,              // 50 MHz clock
    input wire rstn,             // KEY0 - Reset (active low)
    input wire btn_run_test,     // KEY1 - Run next test (active low)
    
    // 7-Segment Display outputs (active low)
    output wire [6:0] HEX0,      // Test number (ones)
    output wire [6:0] HEX1,      // Test number (tens)
    output wire [6:0] HEX2,      // Pass count (ones)
    output wire [6:0] HEX3,      // Pass count (tens)
    output wire [6:0] HEX4,      // Error magnitude display
    output wire [6:0] HEX5,      // Status display
    
    // LED outputs
    output reg led_pass,                    // LEDR[0] - Test passed
    output reg led_fail,                    // LEDR[1] - Test failed
    output reg led_busy,                    // LEDR[2] - Processing
    output reg led_done,                    // LEDR[3] - All tests complete
    output reg [5:0] led_test_progress      // LEDR[9:4] - Visual test progress
);

    // ===== State Machine =====
    localparam IDLE           = 4'd0,
               LOAD_TEST      = 4'd1,
               RUN_GRU        = 4'd2,
               WAIT_GRU       = 4'd3,
               CHECK_RESULT   = 4'd4,
               DISPLAY_RESULT = 4'd5,
               NEXT_TEST      = 4'd6,
               ALL_DONE       = 4'd7;
    
    reg [3:0] state;
    reg [7:0] current_test;
    reg [7:0] tests_passed;
    
    // ===== Test Data Storage =====
    reg [DATA_WIDTH-1:0] test_inputs_mem [0:(NUM_TEST_CASES*SEQUENCE_LENGTH*INPUT_FEATURES)-1];
    reg [DATA_WIDTH-1:0] expected_outputs_mem [0:NUM_TEST_CASES-1];
    
    initial begin
        $readmemh("test_input.mem", test_inputs_mem);
        $readmemh("test_output.mem", expected_outputs_mem);
    end
    
    // ===== Current Test Data =====
    reg [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] current_sequence;
    reg [DATA_WIDTH-1:0] expected_output;
    wire [DATA_WIDTH-1:0] gru_prediction;
    
    // ===== 7-Segment Display Data =====
    reg [3:0] hex0_data, hex1_data, hex2_data, hex3_data, hex4_data, hex5_data;
    
    // ===== 7-Segment Decoder Instances =====
    hex_to_7seg hex0_inst (.hex(hex0_data), .seg(HEX0));
    hex_to_7seg hex1_inst (.hex(hex1_data), .seg(HEX1));
    hex_to_7seg hex2_inst (.hex(hex2_data), .seg(HEX2));
    hex_to_7seg hex3_inst (.hex(hex3_data), .seg(HEX3));
    hex_to_7seg hex4_inst (.hex(hex4_data), .seg(HEX4));
    hex_to_7seg hex5_inst (.hex(hex5_data), .seg(HEX5));
    
    // ===== GRU Model Instance =====
    reg gru_start;
    wire gru_done;
    
    GRU_Model #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_FEATURES(INPUT_FEATURES),
        .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH)
    ) gru_inst (
        .clk(clk),
        .rstn(rstn),
        .i_start(gru_start),
        .o_done(gru_done),
        .i_sequence_flat(current_sequence),
        .o_prediction(gru_prediction)
    );
    
    // ===== Button Edge Detection =====
    reg [2:0] btn_sync;
    wire btn_run_pressed;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            btn_sync <= 3'b111;
        else
            btn_sync <= {btn_sync[1:0], btn_run_test};
    end
    
    assign btn_run_pressed = (btn_sync[2:1] == 2'b11) && !btn_sync[0];
    
    // ===== Simple Error Check (Compare exponent and sign) =====
    reg test_passed;
    wire [7:0] pred_exp, exp_exp;
    wire pred_sign, exp_sign;
    wire [7:0] exp_diff;
    
    assign pred_sign = gru_prediction[31];
    assign exp_sign = expected_output[31];
    assign pred_exp = gru_prediction[30:23];
    assign exp_exp = expected_output[30:23];
    
    // Calculate exponent difference (unsigned)
    assign exp_diff = (pred_exp > exp_exp) ? (pred_exp - exp_exp) : (exp_exp - pred_exp);
    
    // Pass if signs match and exponent difference is small (within 3)
    wire signs_match = (pred_sign == exp_sign);
    wire exp_close = (exp_diff <= 8'd3);
    wire result_pass = signs_match && exp_close;
    
    // ===== Display Timer =====
    reg [26:0] display_counter;
    wire display_timeout;
    assign display_timeout = (display_counter >= 27'd50_000_000); // 1 second
    
    // ===== Main State Machine =====
    integer i, base_idx;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= IDLE;
            current_test <= 0;
            tests_passed <= 0;
            gru_start <= 0;
            led_pass <= 0;
            led_fail <= 0;
            led_busy <= 0;
            led_done <= 0;
            current_sequence <= 0;
            expected_output <= 0;
            test_passed <= 0;
            display_counter <= 0;
            led_test_progress <= 0;
            
            // Initialize displays
            hex0_data <= 4'd0;
            hex1_data <= 4'd0;
            hex2_data <= 4'd0;
            hex3_data <= 4'd0;
            hex4_data <= 4'hE;  // 'E' for ready
            hex5_data <= 4'hE;  // 'E' for ready
            
        end else begin
            case (state)
                IDLE: begin
                    led_busy <= 0;
                    led_pass <= 0;
                    led_fail <= 0;
                    gru_start <= 0;
                    display_counter <= 0;
                    
                    // Show current test number
                    hex0_data <= current_test % 10;
                    hex1_data <= current_test / 10;
                    
                    // Show pass count
                    hex2_data <= tests_passed % 10;
                    hex3_data <= tests_passed / 10;
                    
                    // Status display
                    if (current_test >= NUM_TEST_CASES) begin
                        hex5_data <= 4'hD;  // 'D' for done
                        hex4_data <= 4'h0;  // '0'
                        state <= ALL_DONE;
                    end else begin
                        hex5_data <= 4'hE;  // 'E' for ready
                        hex4_data <= 4'd0;
                        if (btn_run_pressed) begin
                            state <= LOAD_TEST;
                        end
                    end
                    
                    // Visual progress bar on LEDs
                    led_test_progress <= (6'b111111 >> (6 - current_test)) & 6'b111111;
                end
                
                LOAD_TEST: begin
                    led_busy <= 1;
                    hex5_data <= 4'hC;  // 'C' for computing
                    
                    // Load test sequence
                    base_idx = current_test * SEQUENCE_LENGTH * INPUT_FEATURES;
                    for (i = 0; i < SEQUENCE_LENGTH * INPUT_FEATURES; i = i + 1) begin
                        current_sequence[i*DATA_WIDTH +: DATA_WIDTH] <= test_inputs_mem[base_idx + i];
                    end
                    expected_output <= expected_outputs_mem[current_test];
                    
                    state <= RUN_GRU;
                end
                
                RUN_GRU: begin
                    gru_start <= 1;
                    state <= WAIT_GRU;
                end
                
                WAIT_GRU: begin
                    if (gru_done) begin
                        gru_start <= 0;
                        state <= CHECK_RESULT;
                    end
                end
                
                CHECK_RESULT: begin
                    if (!gru_done) begin
                        // Evaluate result
                        test_passed <= result_pass;
                        
                        if (result_pass) begin
                            tests_passed <= tests_passed + 1;
                        end
                        
                        // Show error magnitude on HEX4
                        if (exp_diff == 0)
                            hex4_data <= 4'd0;  // Perfect match
                        else if (exp_diff == 1)
                            hex4_data <= 4'd1;  // Very small error
                        else if (exp_diff == 2)
                            hex4_data <= 4'd2;  // Small error
                        else if (exp_diff == 3)
                            hex4_data <= 4'd3;  // Acceptable error
                        else
                            hex4_data <= 4'hF;  // Large error
                        
                        // Show pass/fail status
                        hex5_data <= result_pass ? 4'hA : 4'hF;  // 'A' = pass, 'F' = fail
                        
                        state <= DISPLAY_RESULT;
                    end
                end
                
                DISPLAY_RESULT: begin
                    led_busy <= 0;
                    led_pass <= test_passed;
                    led_fail <= !test_passed;
                    
                    display_counter <= display_counter + 1;
                    
                    // Blink LEDs for visual feedback
                    if (display_counter[23]) begin
                        led_pass <= test_passed & display_counter[22];
                        led_fail <= !test_passed & display_counter[22];
                    end
                    
                    if (display_timeout || btn_run_pressed) begin
                        state <= NEXT_TEST;
                    end
                end
                
                NEXT_TEST: begin
                    led_pass <= 0;
                    led_fail <= 0;
                    current_test <= current_test + 1;
                    display_counter <= 0;
                    state <= IDLE;
                end
                
                ALL_DONE: begin
                    led_done <= 1;
                    led_busy <= 0;
                    
                    // Show final results
                    hex0_data <= tests_passed % 10;
                    hex1_data <= tests_passed / 10;
                    hex2_data <= NUM_TEST_CASES % 10;
                    hex3_data <= NUM_TEST_CASES / 10;
                    hex4_data <= 4'h0;
                    hex5_data <= 4'hD;  // 'D' for done
                    
                    // Animate LEDs to show all tests complete
                    led_test_progress <= tests_passed[5:0];
                    
                    // All tests passed - celebrate!
                    if (tests_passed == NUM_TEST_CASES) begin
                        led_pass <= display_counter[23];  // Blink
                    end else begin
                        led_fail <= display_counter[23];  // Blink if some failed
                    end
                    
                    display_counter <= display_counter + 1;
                    
                    // Reset on button press
                    if (btn_run_pressed) begin
                        current_test <= 0;
                        tests_passed <= 0;
                        led_done <= 0;
                        led_pass <= 0;
                        led_fail <= 0;
                        led_test_progress <= 0;
                        display_counter <= 0;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule

// ===== 7-Segment Decoder Module =====
module hex_to_7seg (
    input wire [3:0] hex,
    output reg [6:0] seg
);
    // 7-segment encoding (active low): gfedcba
    always @(*) begin
        case (hex)
            4'h0: seg = 7'b1000000; // 0
            4'h1: seg = 7'b1111001; // 1
            4'h2: seg = 7'b0100100; // 2
            4'h3: seg = 7'b0110000; // 3
            4'h4: seg = 7'b0011001; // 4
            4'h5: seg = 7'b0010010; // 5
            4'h6: seg = 7'b0000010; // 6
            4'h7: seg = 7'b1111000; // 7
            4'h8: seg = 7'b0000000; // 8
            4'h9: seg = 7'b0010000; // 9
            4'hA: seg = 7'b0001000; // A (pass)
            4'hB: seg = 7'b0000011; // b
            4'hC: seg = 7'b1000110; // C (computing)
            4'hD: seg = 7'b0100001; // d (done)
            4'hE: seg = 7'b0000110; // E (ready)
            4'hF: seg = 7'b0001110; // F (fail)
            default: seg = 7'b1111111; // blank
        endcase
    end
endmodule