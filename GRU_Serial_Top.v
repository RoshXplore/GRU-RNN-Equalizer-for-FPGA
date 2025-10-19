`timescale 1ns / 1ps

module GRU_Serial_Top #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 3,
    parameter GRU_UNITS = 3,
    parameter SEQUENCE_LENGTH = 3,
    parameter OUTPUT_SIZE = 1
)(
    input wire clk,
    input wire rstn,
    input wire btn_start,
    
    input wire serial_data_in,
    input wire serial_clk_in,
    input wire serial_load_en,
    
    output reg serial_data_out,
    output reg serial_clk_out,
    output reg serial_valid,
    
    output reg led_done,
    output reg led_ready,
    output reg led_loading,
    output reg [3:0] led_state
);

    localparam IDLE         = 4'd0,
               WAIT_WEIGHTS = 4'd1,
               LOAD_SERIAL  = 4'd2,
               READY        = 4'd3,
               RUN_GRU      = 4'd4,
               WAIT_GRU     = 4'd5,
               SEND_SERIAL  = 4'd6,
               DONE         = 4'd7;
    
    reg [3:0] state;
    
    // Input sequence storage
    reg [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] sequence_flat;
    
    // Serial input handling
    reg [DATA_WIDTH-1:0] serial_shift_reg;
    reg [5:0] bit_count;
    reg [3:0] word_count;
    
    // Serial output handling
    reg [DATA_WIDTH-1:0] output_data_latched;
    reg [5:0] output_bits_sent;
    reg [3:0] output_phase;
    
    // GRU Model
    reg gru_start;
    wire gru_done;
    wire [DATA_WIDTH-1:0] gru_prediction;
    
    GRU_Model #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_FEATURES(INPUT_FEATURES),
        .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH),
        .OUTPUT_SIZE(OUTPUT_SIZE)
    ) gru_inst (
        .clk(clk),
        .rstn(rstn),
        .i_start(gru_start),
        .o_done(gru_done),
        .i_sequence_flat(sequence_flat),
        .o_prediction(gru_prediction)
    );
    
    // Edge detection
    reg btn_start_d1, btn_start_d2;
    reg serial_clk_d1, serial_clk_d2;
    wire btn_start_pressed;
    wire serial_clk_posedge;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            btn_start_d1 <= 0;
            btn_start_d2 <= 0;
            serial_clk_d1 <= 0;
            serial_clk_d2 <= 0;
        end else begin
            btn_start_d2 <= btn_start_d1;
            btn_start_d1 <= btn_start;
            serial_clk_d2 <= serial_clk_d1;
            serial_clk_d1 <= serial_clk_in;
        end
    end
    
    assign btn_start_pressed = btn_start_d1 && !btn_start_d2;
    assign serial_clk_posedge = serial_clk_d1 && !serial_clk_d2;
    
    // Serial input handler
    reg serial_complete;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            serial_shift_reg <= 0;
            bit_count <= 0;
            word_count <= 0;
            sequence_flat <= 0;
            serial_complete <= 0;
        end else begin
            if (state == LOAD_SERIAL && serial_load_en) begin
                serial_complete <= 0;
                if (serial_clk_posedge) begin
                    
                    if (bit_count == DATA_WIDTH - 1) begin
                        sequence_flat[word_count*DATA_WIDTH +: DATA_WIDTH] <= 
                            {serial_shift_reg[DATA_WIDTH-2:0], serial_data_in};
                        
                        bit_count <= 0;

                        if (word_count == (SEQUENCE_LENGTH * INPUT_FEATURES) - 1) begin
                            serial_complete <= 1;
                        end else begin
                            word_count <= word_count + 1;
                        end
                    end else begin
                        serial_shift_reg <= {serial_shift_reg[DATA_WIDTH-2:0], serial_data_in};
                        bit_count <= bit_count + 1;
                    end
                end
            end else if (state == WAIT_WEIGHTS) begin
                bit_count <= 0;
                word_count <= 0;
                serial_complete <= 0;
            end
        end
    end
    
    // Serial output handler
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            output_data_latched <= 0;
            output_bits_sent <= 0;
            output_phase <= 0;
            serial_data_out <= 0;
            serial_clk_out <= 0;
            serial_valid <= 0;
        end else begin
            if (state == SEND_SERIAL) begin
                case (output_phase)
                    4'd0: begin
                        output_data_latched <= gru_prediction;
                        output_bits_sent <= 0;
                        serial_valid <= 1;
                        serial_clk_out <= 0;
                        serial_data_out <= gru_prediction[DATA_WIDTH-1];
                        output_phase <= 1;
                    end
                    
                    4'd1: begin
                        serial_clk_out <= 0;
                        output_phase <= 2;
                    end
                    
                    4'd2: begin
                        serial_clk_out <= 1;
                        output_bits_sent <= output_bits_sent + 1;
                        output_phase <= 3;
                    end
                    
                    4'd3: begin
                        serial_clk_out <= 0;
                        if (output_bits_sent >= DATA_WIDTH) begin
                            output_phase <= 4;
                        end else begin
                            serial_data_out <= output_data_latched[DATA_WIDTH - 1 - output_bits_sent];
                            output_phase <= 1;
                        end
                    end
                    
                    4'd4: begin
                        serial_clk_out <= 0;
                        serial_valid <= 0;
                        output_phase <= 5;
                    end
                    
                    default: begin
                        serial_clk_out <= 0;
                        serial_valid <= 0;
                    end
                endcase
            end else begin
                output_phase <= 0;
                output_bits_sent <= 0;
                serial_clk_out <= 0;
                serial_valid <= 0;
            end
        end
    end
    
    // Weight loading detection
    reg weights_ready;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            weights_ready <= 0;
        end else begin
            weights_ready <= 1;
        end
    end
    
    // DONE state holding - use a counter to hold the state
    reg [15:0] done_hold_counter;
    parameter DONE_HOLD_CYCLES = 16'd1000; // Hold DONE for 1000 cycles (20us @ 50MHz)
    
    // Main state machine
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= IDLE;
            gru_start <= 0;
            led_done <= 0;
            led_ready <= 0;
            led_loading <= 0;
            led_state <= 0;
            done_hold_counter <= 0;
        end else begin
            led_state <= state;
            
            case (state)
                IDLE: begin
                    done_hold_counter <= 0;
                    if (weights_ready) begin
                        state <= WAIT_WEIGHTS;
                    end
                end
                
                WAIT_WEIGHTS: begin
                    led_ready <= 1;
                    led_loading <= 0;
                    led_done <= 0;
                    done_hold_counter <= 0;
                    if (serial_load_en) begin
                        led_ready <= 0;
                        state <= LOAD_SERIAL;
                    end
                end
                
                LOAD_SERIAL: begin
                    led_loading <= 1;
                    if (serial_complete) begin
                        state <= READY;
                    end
                end
                
                READY: begin
                    led_ready <= 1;
                    led_loading <= 0;
                    if (btn_start_pressed) begin
                        led_ready <= 0;
                        state <= RUN_GRU;
                    end
                end
                
                RUN_GRU: begin
                    gru_start <= 1;
                    state <= WAIT_GRU;
                end
                
                WAIT_GRU: begin
                    gru_start <= 1;
                    if (gru_done) begin
                        gru_start <= 0;
                        state <= SEND_SERIAL;
                    end
                end
                
                SEND_SERIAL: begin
                    gru_start <= 0;
                    if (output_phase == 5) begin
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    gru_start <= 0;
                    led_done <= 1;
                    
                    // Increment counter
                    if (done_hold_counter < DONE_HOLD_CYCLES) begin
                        done_hold_counter <= done_hold_counter + 1;
                    end else begin
                        // Minimum hold time met, can exit when button is released
                        if (!btn_start) begin
                            led_done <= 0;
                            done_hold_counter <= 0;
                            state <= WAIT_WEIGHTS;
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule