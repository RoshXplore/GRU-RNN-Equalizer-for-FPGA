`timescale 1ns / 1ps
module dot_product_top #(
    parameter DATA_WIDTH = 32,
    parameter MAX_VECTOR_SIZE = 7
)(
    input clk,
    input rstn,
    // Serial data interface
    input [DATA_WIDTH-1:0] data_in,
    input [2:0] write_addr,
    input write_en_a,
    input write_en_b,
    // Dot product control
    input start_calc,
    input [3:0] vector_length,
    output reg calc_done,
    output [DATA_WIDTH-1:0] result
);
    // --- Internal RAMs for vectors ---
    reg [DATA_WIDTH-1:0] vector_a_ram [0:MAX_VECTOR_SIZE-1];
    reg [DATA_WIDTH-1:0] vector_b_ram [0:MAX_VECTOR_SIZE-1];
    integer i;
    
    always @(posedge clk) begin
        if (write_en_a) vector_a_ram[write_addr] <= data_in;
        if (write_en_b) vector_b_ram[write_addr] <= data_in;
    end
    
    // --- Flattened vectors for core ---
    reg [DATA_WIDTH*MAX_VECTOR_SIZE-1:0] core_vec_a_flat;
    reg [DATA_WIDTH*MAX_VECTOR_SIZE-1:0] core_vec_b_flat;
    reg core_start;
    wire core_done;
    wire [DATA_WIDTH-1:0] core_result;
    
    // *** FIX: Pack vectors with proper timing ***
    always @(posedge clk) begin
        for (i = 0; i < MAX_VECTOR_SIZE; i=i+1) begin
            core_vec_a_flat[DATA_WIDTH*i +: DATA_WIDTH] <= vector_a_ram[i];
            core_vec_b_flat[DATA_WIDTH*i +: DATA_WIDTH] <= vector_b_ram[i];
        end
    end
    
    dot_product u_dot_product_core (
        .clk(clk), .rstn(rstn),
        .start(core_start),
        .done(core_done),
        .vector_a_flat(core_vec_a_flat),
        .vector_b_flat(core_vec_b_flat),
        .vector_length(vector_length),
        .result(core_result)
    );
    
    // --- FSM for top-level control ---
    localparam S_IDLE       = 0,
               S_START_CORE = 1,
               S_WAIT_CORE  = 2;
    
    reg [1:0] state;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            calc_done <= 0;
            core_start <= 0;
        end else begin
            // Default
            core_start <= 0;
            calc_done <= 0;
            
            case(state)
                S_IDLE: begin
                    if (start_calc) begin
                        core_start <= 1; // pulse handshake
                        state <= S_WAIT_CORE;
                    end
                end
                
                S_WAIT_CORE: begin
                    if (core_done) begin
                        calc_done <= 1;
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
    
    assign result = core_result;
endmodule