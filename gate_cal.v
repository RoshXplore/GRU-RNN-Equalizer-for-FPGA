`timescale 1ns / 1ps

module gate_cal #(
    parameter DATA_WIDTH = 32,
    parameter GRU_UNITS = 7,
    parameter INPUT_FEATURES = 3
)(
    input clk,
    input rstn,
    input start,
    output reg done,
    input activation_type, // 0 for sigmoid, 1 for tanh
    input [(INPUT_FEATURES * DATA_WIDTH)-1:0] i_input_vector_flat,
    input [(GRU_UNITS * DATA_WIDTH)-1:0]      i_hidden_vector_flat,
    input [(INPUT_FEATURES * DATA_WIDTH)-1:0] i_W_weights_flat,
    input [(GRU_UNITS * DATA_WIDTH)-1:0]      i_U_weights_flat,
    input [DATA_WIDTH-1:0]                    bias,
    output reg [DATA_WIDTH-1:0] gate_result
);
    // --- FSM States ---
    reg [3:0] state;
    localparam S_IDLE           = 4'd0,
               S_START_DP       = 4'd1,
               S_WAIT_DP        = 4'd2,
               S_WAIT_DP_IDLE   = 4'd3,
               S_START_SUM      = 4'd4,
               S_WAIT_SUM       = 4'd5,
               S_WAIT_SUM_IDLE  = 4'd6,
               S_START_BIAS     = 4'd7,
               S_WAIT_BIAS      = 4'd8,
               S_WAIT_BIAS_IDLE = 4'd9,
               S_START_ACT      = 4'd10,
               S_WAIT_ACT       = 4'd11,
               S_WAIT_ACT_IDLE  = 4'd12,
               S_DONE           = 4'd13;
    
    // --- Control & Data Signals ---
    reg dp_wx_start, dp_uh_start, sum_dp_start, add_bias_start, act_start;
    wire dp_wx_done, dp_uh_done, sum_dp_done, add_bias_done;
    wire [DATA_WIDTH-1:0] dp_wx_result, dp_uh_result, sum_dp_result, add_bias_result;

    reg [DATA_WIDTH-1:0] activation_input;
    reg [DATA_WIDTH-1:0] dp_wx_latched, dp_uh_latched;

    // Separate signals for each activation unit
    wire sigmoid_done, tanh_done;
    wire [DATA_WIDTH-1:0] sigmoid_result, tanh_result;
    wire act_done;
    wire [DATA_WIDTH-1:0] act_result;
    
    // --- Instantiate Workers ---
    // Dot product: W·x
    dot_product #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_VECTOR_SIZE(INPUT_FEATURES)
    ) DPU_WX (
        .clk(clk), 
        .rstn(rstn), 
        .start(dp_wx_start), 
        .done(dp_wx_done), 
        .vector_length(INPUT_FEATURES[3:0]),
        .vector_a_flat(i_W_weights_flat), 
        .vector_b_flat(i_input_vector_flat), 
        .result(dp_wx_result)
    );
    
    // Dot product: U·h
    dot_product #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_VECTOR_SIZE(GRU_UNITS)
    ) DPU_UH (
        .clk(clk), 
        .rstn(rstn), 
        .start(dp_uh_start), 
        .done(dp_uh_done), 
        .vector_length(GRU_UNITS[3:0]),
        .vector_a_flat(i_U_weights_flat), 
        .vector_b_flat(i_hidden_vector_flat), 
        .result(dp_uh_result)
    );
    
    // Adder: sum = W·x + U·h
    adder ADDER_SUM (
        .clk(clk), 
        .rstn(rstn), 
        .start(sum_dp_start), 
        .done(sum_dp_done), 
        .value_in(dp_wx_latched), 
        .bias(dp_uh_latched), 
        .value_out(sum_dp_result)
    );
    
    // Adder: result = sum + bias
    adder ADDER_BIAS (
        .clk(clk), 
        .rstn(rstn), 
        .start(add_bias_start), 
        .done(add_bias_done), 
        .value_in(sum_dp_result), 
        .bias(bias), 
        .value_out(add_bias_result)
    );
    
    // --- Activation Units ---
    // Sigmoid
    SigMoid SIG_inst (
        .clk(clk), 
        .rstn(rstn), 
        .start(act_start && (activation_type == 0)),
        .done(sigmoid_done), 
        .mult_sum_in(activation_input),
        .neuron_out(sigmoid_result)
    );
    
    // Tanh instantiation
    tanh TANH_inst (
        .clk(clk),
        .rstn(rstn),
        .start(act_start && (activation_type == 1)),
        .done(tanh_done),
        .in_fp(activation_input),
        .out_fp(tanh_result)
    );

    // Multiplex the done and result signals from the active activation unit
    assign act_done = (activation_type == 0) ? sigmoid_done : tanh_done;
    assign act_result = (activation_type == 0) ? sigmoid_result : tanh_result;

    // --- Sequential Logic (FSM) with PROPER HANDSHAKING ---
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            done <= 1'b0;
            gate_result <= 0;
            dp_wx_start <= 1'b0;
            dp_uh_start <= 1'b0;
            sum_dp_start <= 1'b0;
            add_bias_start <= 1'b0;
            act_start <= 1'b0;
            activation_input <= 0;
            dp_wx_latched <= 0;
            dp_uh_latched <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    done <= 1'b0;
                    dp_wx_start <= 1'b0;
                    dp_uh_start <= 1'b0;
                    sum_dp_start <= 1'b0;
                    add_bias_start <= 1'b0;
                    act_start <= 1'b0;
                    
                    if (start) begin
                        state <= S_START_DP;
                    end
                end
                
                // ===== DOT PRODUCTS =====
                S_START_DP: begin
                    dp_wx_start <= 1'b1;
                    dp_uh_start <= 1'b1;
                    state <= S_WAIT_DP;
                end
                
                S_WAIT_DP: begin
                    dp_wx_start <= 1'b1;
                    dp_uh_start <= 1'b1;
                    
                    if (dp_wx_done && dp_uh_done) begin
                        // Latch results
                        dp_wx_latched <= dp_wx_result;
                        dp_uh_latched <= dp_uh_result;
                        
                        $display("[%0t] [GateCal] W·x = %h (%.6f)", $time, dp_wx_result, $bitstoreal(dp_wx_result));
                        $display("[%0t] [GateCal] U·h = %h (%.6f)", $time, dp_uh_result, $bitstoreal(dp_uh_result));
                        
                        // De-assert starts
                        dp_wx_start <= 1'b0;
                        dp_uh_start <= 1'b0;
                        state <= S_WAIT_DP_IDLE;
                    end
                end
                
                S_WAIT_DP_IDLE: begin
                    dp_wx_start <= 1'b0;
                    dp_uh_start <= 1'b0;
                    
                    if (!dp_wx_done && !dp_uh_done) begin
                        state <= S_START_SUM;
                    end
                end
                
                // ===== SUM (W·x + U·h) =====
                S_START_SUM: begin
                    sum_dp_start <= 1'b1;
                    state <= S_WAIT_SUM;
                end
                
                S_WAIT_SUM: begin
                    sum_dp_start <= 1'b1;
                    
                    if (sum_dp_done) begin
                        $display("[%0t] [GateCal] W·x + U·h = %h (%.6f)", $time, sum_dp_result, $bitstoreal(sum_dp_result));
                        sum_dp_start <= 1'b0;
                        state <= S_WAIT_SUM_IDLE;
                    end
                end
                
                S_WAIT_SUM_IDLE: begin
                    sum_dp_start <= 1'b0;
                    
                    if (!sum_dp_done) begin
                        state <= S_START_BIAS;
                    end
                end
                
                // ===== ADD BIAS =====
                S_START_BIAS: begin
                    add_bias_start <= 1'b1;
                    state <= S_WAIT_BIAS;
                end
                
                S_WAIT_BIAS: begin
                    add_bias_start <= 1'b1;
                    
                    if (add_bias_done) begin
                        activation_input <= add_bias_result;
                        $display("[%0t] [GateCal] After bias = %h (%.6f)", $time, add_bias_result, $bitstoreal(add_bias_result));
                        $display("[%0t]           EXPECTED: 3f0d2310 (0.551316)", $time);
                        
                        add_bias_start <= 1'b0;
                        state <= S_WAIT_BIAS_IDLE;
                    end
                end
                
                S_WAIT_BIAS_IDLE: begin
                    add_bias_start <= 1'b0;
                    
                    if (!add_bias_done) begin
                        state <= S_START_ACT;
                    end
                end
                
                // ===== ACTIVATION =====
                S_START_ACT: begin
                    act_start <= 1'b1;
                    state <= S_WAIT_ACT;
                end
                
                S_WAIT_ACT: begin
                    act_start <= 1'b1;
                    
                    if (act_done) begin
                        gate_result <= act_result;
                        $display("[%0t] [GateCal] After activation = %h (%.6f)", $time, act_result, $bitstoreal(act_result));
                        
                        act_start <= 1'b0;
                        state <= S_WAIT_ACT_IDLE;
                    end
                end
                
                S_WAIT_ACT_IDLE: begin
                    act_start <= 1'b0;
                    
                    if (!act_done) begin
                        state <= S_DONE;
                    end
                end
                
                // ===== DONE =====
                S_DONE: begin
                    done <= 1'b1;
                    
                    if (!start) begin
                        done <= 1'b0;
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule