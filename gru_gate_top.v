`timescale 1ns / 1ps

module gru_gate_top #(
    parameter DATA_WIDTH = 32,
    parameter GRU_UNITS = 7,
    parameter INPUT_FEATURES = 3
)(
    // Simple, narrow interface for the outside world
    input clk,
    input rstn,
    input start_process,
    output reg done_process,

    // Interface for loading data into internal memories
    input [DATA_WIDTH-1:0] i_data,
    input [7:0] i_addr,
    input i_we,

    // Configuration and final result
    input i_activation_type,
    output [DATA_WIDTH-1:0] o_result
);

    // --- Internal On-Chip Memories ---
    reg [DATA_WIDTH-1:0] w_weights_mem [0:INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] u_weights_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] input_vector_mem [0:INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] hidden_vector_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bias_reg;

    integer m;

    // --- Memory write and reset logic ---
    // --- FIX: Restructured to make bias write mutually exclusive ---
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            // Initialize all memories to a known state (0) on reset
            for (m = 0; m < INPUT_FEATURES; m = m + 1) begin
                w_weights_mem[m] <= 0;
                input_vector_mem[m] <= 0;
            end
            for (m = 0; m < GRU_UNITS; m = m + 1) begin
                u_weights_mem[m] <= 0;
                hidden_vector_mem[m] <= 0;
            end
            bias_reg <= 0;
        end else if (i_we) begin
            // Memory write logic now only runs when not in reset
            if (i_addr == 8'hF0) begin
                bias_reg <= i_data;
            end else begin
                case (i_addr[7:6])
                    2'b00: w_weights_mem[i_addr[3:0]] <= i_data;
                    2'b01: u_weights_mem[i_addr[3:0]] <= i_data;
                    2'b10: input_vector_mem[i_addr[3:0]] <= i_data;
                    2'b11: hidden_vector_mem[i_addr[3:0]] <= i_data;
                    default:;
                endcase
            end
        end
    end

    // --- STEP 1: Combinational Packing Logic (Unchanged) ---
    wire [(INPUT_FEATURES * DATA_WIDTH)-1:0] w_weights_flat_wire;
    wire [(GRU_UNITS * DATA_WIDTH)-1:0]      u_weights_flat_wire;
    wire [(INPUT_FEATURES * DATA_WIDTH)-1:0] input_vector_flat_wire;
    wire [(GRU_UNITS * DATA_WIDTH)-1:0]      hidden_vector_flat_wire;
    genvar i, j, k, l;

    generate
        for (i = 0; i < INPUT_FEATURES; i = i + 1) begin : w_pack
            assign w_weights_flat_wire[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH] = w_weights_mem[i];
        end
        for (j = 0; j < GRU_UNITS; j = j + 1) begin : u_pack
            assign u_weights_flat_wire[(j+1)*DATA_WIDTH-1 : j*DATA_WIDTH] = u_weights_mem[j];
        end
        for (k = 0; k < INPUT_FEATURES; k = k + 1) begin : x_pack
            assign input_vector_flat_wire[(k+1)*DATA_WIDTH-1 : k*DATA_WIDTH] = input_vector_mem[k];
        end
        for (l = 0; l < GRU_UNITS; l = l + 1) begin : h_pack
            assign hidden_vector_flat_wire[(l+1)*DATA_WIDTH-1 : l*DATA_WIDTH] = hidden_vector_mem[l];
        end
    endgenerate

    // --- FSM State Declarations (MOVED) ---
    reg [2:0] state;
    localparam S_IDLE          = 3'd0,
               S_LATCH         = 3'd1, // State to enable latching the data
               S_START_COMPUTE = 3'd2, // State to start the worker module
               S_COMPUTE       = 3'd3,
               S_DONE          = 3'd4;

    reg gate_cal_start;
    wire gate_cal_done;

    // --- STEP 2: Sequential Latching of Packed Data ---
    reg [(INPUT_FEATURES * DATA_WIDTH)-1:0] w_weights_flat_reg;
    reg [(GRU_UNITS * DATA_WIDTH)-1:0]      u_weights_flat_reg;
    reg [(INPUT_FEATURES * DATA_WIDTH)-1:0] input_vector_flat_reg;
    reg [(GRU_UNITS * DATA_WIDTH)-1:0]      hidden_vector_flat_reg;
    // --- FIX: Added a latched register for the bias value ---
    reg [DATA_WIDTH-1:0]                    bias_reg_latched;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            w_weights_flat_reg   <= 0;
            u_weights_flat_reg   <= 0;
            input_vector_flat_reg <= 0;
            hidden_vector_flat_reg<= 0;
            bias_reg_latched     <= 0;
        // The latch enable is now explicitly controlled by the FSM's S_LATCH state
        end else if (state == S_LATCH) begin
            w_weights_flat_reg    <= w_weights_flat_wire;
            u_weights_flat_reg    <= u_weights_flat_wire;
            input_vector_flat_reg <= input_vector_flat_wire;
            hidden_vector_flat_reg<= hidden_vector_flat_wire;
            bias_reg_latched      <= bias_reg;
        end
    end

    // --- STEP 3: FSM Logic ---
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            gate_cal_start <= 1'b0;
            done_process <= 1'b0;
        end else begin
            gate_cal_start <= 1'b0; // Default to off
            done_process <= 1'b0;
            
            case(state)
                S_IDLE: begin
                    if (start_process) begin
                        state <= S_LATCH;
                    end
                end
                S_LATCH: begin
                    state <= S_START_COMPUTE;
                end
                S_START_COMPUTE: begin
                    gate_cal_start <= 1'b1;
                    state <= S_COMPUTE;
                end
                S_COMPUTE: begin
                    if (gate_cal_done) begin
                        state <= S_DONE;
                    end
                end
                S_DONE: begin
                    done_process <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
    
    // --- Instantiate the gate_cal Worker Module ---
    gate_cal #(
        .DATA_WIDTH(DATA_WIDTH),
        .GRU_UNITS(GRU_UNITS),
        .INPUT_FEATURES(INPUT_FEATURES)
    ) u_gate_cal (
        .clk(clk),
        .rstn(rstn),
        .start(gate_cal_start),
        .done(gate_cal_done),
        .activation_type(i_activation_type),
        .i_input_vector_flat(input_vector_flat_reg),
        .i_hidden_vector_flat(hidden_vector_flat_reg),
        .i_W_weights_flat(w_weights_flat_reg),
        .i_U_weights_flat(u_weights_flat_reg),
        // --- FIX: Connected worker to the new latched bias register ---
        .bias(bias_reg_latched),
        .gate_result(o_result)
    );

endmodule

