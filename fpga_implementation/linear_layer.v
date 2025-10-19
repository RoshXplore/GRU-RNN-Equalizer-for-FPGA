`timescale 1ns / 1ps

module linear_layer #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_VECTOR_SIZE = 3
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,

    input wire [(INPUT_VECTOR_SIZE * DATA_WIDTH)-1:0] i_input_vector_flat,
    input wire [(INPUT_VECTOR_SIZE * DATA_WIDTH)-1:0] i_fc_weights_flat,
    input wire [DATA_WIDTH-1:0]                       i_fc_bias,
    output reg [DATA_WIDTH-1:0] o_final_prediction
);

    // --- State Machine ---
    localparam S_IDLE       = 4'd0,
               S_START_DP   = 4'd1,
               S_WAIT_DP    = 4'd2,
               S_WAIT_DP_ACK = 4'd3,
               S_START_ADD  = 4'd4,
               S_WAIT_ADD   = 4'd5,
               S_WAIT_ADD_ACK = 4'd6,
               S_DONE       = 4'd7;
    reg [3:0] state;

    // --- Control Signals ---
    reg dp_start, add_start;
    wire dp_done, add_done;
    wire [DATA_WIDTH-1:0] dp_result;
    wire [DATA_WIDTH-1:0] final_add_result_wire;

    // --- Module Instantiations ---
    dot_product #(
        .MAX_VECTOR_SIZE(INPUT_VECTOR_SIZE)
    ) fc_dot_product (
        .clk(clk), 
        .rstn(rstn), 
        .start(dp_start), 
        .done(dp_done),
        .vector_length(INPUT_VECTOR_SIZE[3:0]),
        .vector_a_flat(i_input_vector_flat),
        .vector_b_flat(i_fc_weights_flat),
        .result(dp_result)
    );

    adder #(.DATA_WIDTH(DATA_WIDTH)) fc_adder (
        .clk(clk), 
        .rstn(rstn),
        .start(add_start), 
        .done(add_done),
        .value_in(dp_result),
        .bias(i_fc_bias),
        .value_out(final_add_result_wire)
    );

    // FSM Logic with Proper Handshaking
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 1'b0;
            dp_start <= 1'b0;
            add_start <= 1'b0;
            o_final_prediction <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_done <= 1'b0;
                    dp_start <= 1'b0;
                    add_start <= 1'b0;
                    if (i_start) begin
                        $display("[%0t] LinearLayer: Starting", $time);
                        state <= S_START_DP;
                    end
                end
                
                S_START_DP: begin
                    dp_start <= 1'b1;
                    state <= S_WAIT_DP;
                end

                S_WAIT_DP: begin
                    dp_start <= 1'b1; // Keep start high
                    if (dp_done) begin
                        $display("[%0t] LinearLayer: DotProduct done, result=%h", $time, dp_result);
                        dp_start <= 1'b0; // De-assert
                        state <= S_WAIT_DP_ACK;
                    end
                end

                S_WAIT_DP_ACK: begin
                    dp_start <= 1'b0;
                    if (!dp_done) begin // Wait for dot_product to return to idle
                        state <= S_START_ADD;
                    end
                end

                S_START_ADD: begin
                    add_start <= 1'b1;
                    state <= S_WAIT_ADD;
                end

                S_WAIT_ADD: begin
                    add_start <= 1'b1; // Keep start high
                    if (add_done) begin
                        $display("[%0t] LinearLayer: Adder done, result=%h", $time, final_add_result_wire);
                        o_final_prediction <= final_add_result_wire;
                        add_start <= 1'b0; // De-assert
                        state <= S_WAIT_ADD_ACK;
                    end
                end

                S_WAIT_ADD_ACK: begin
                    add_start <= 1'b0;
                    if (!add_done) begin // Wait for adder to return to idle
                        state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    o_done <= 1'b1;
                    dp_start <= 1'b0;
                    add_start <= 1'b0;
                    $display("[%0t] LinearLayer: Done asserted", $time);
                    if (!i_start) begin
                        $display("[%0t] LinearLayer: Returning to IDLE", $time);
                        o_done <= 1'b0;
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule