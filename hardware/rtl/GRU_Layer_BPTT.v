`timescale 1ns / 1ps

module GRU_Layer_BPTT #(
    parameter DATA_WIDTH      = 32,
    parameter GRU_UNITS       = 3,
    parameter INPUT_FEATURES  = 2
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_start,
    output reg  o_done,

    input  wire [(INPUT_FEATURES*DATA_WIDTH)-1:0]        i_input_vector_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]             i_prev_hidden_state_flat,
    input  wire [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0]  i_Wr_flat,
    input  wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]       i_Ur_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]             i_br_flat,
    input  wire [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0]  i_Wz_flat,
    input  wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]       i_Uz_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]             i_bz_flat,
    input  wire [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0]  i_Wh_flat,
    input  wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]       i_Uh_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]             i_bh_flat,

    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_new_hidden_state_flat,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_r_gates_cached,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_z_gates_cached,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_h_candidates_cached
);

    reg [3:0] state;
    reg [7:0] unit_idx;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] r_gates_collected;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] r_modified_hidden;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] new_hidden_state_buffer;
    
    reg cell_start;
    wire cell_done;
    wire [DATA_WIDTH-1:0] cell_output, r_gate_out, z_gate_out, h_cand_out;
    reg computation_phase;
    
    reg mult_start;
    wire mult_done;
    wire [DATA_WIDTH-1:0] mult_out;
    reg [DATA_WIDTH-1:0] mult_in1, mult_in2;
    integer mult_index;

    wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] current_Wr = i_Wr_flat[unit_idx*INPUT_FEATURES*DATA_WIDTH +: INPUT_FEATURES*DATA_WIDTH];
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]      current_Ur = i_Ur_flat[unit_idx*GRU_UNITS*DATA_WIDTH +: GRU_UNITS*DATA_WIDTH];
    wire [DATA_WIDTH-1:0]                  current_br = i_br_flat[unit_idx*DATA_WIDTH +: DATA_WIDTH];
    wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] current_Wz = i_Wz_flat[unit_idx*INPUT_FEATURES*DATA_WIDTH +: INPUT_FEATURES*DATA_WIDTH];
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]      current_Uz = i_Uz_flat[unit_idx*GRU_UNITS*DATA_WIDTH +: GRU_UNITS*DATA_WIDTH];
    wire [DATA_WIDTH-1:0]                  current_bz = i_bz_flat[unit_idx*DATA_WIDTH +: DATA_WIDTH];
    wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] current_Wh = i_Wh_flat[unit_idx*INPUT_FEATURES*DATA_WIDTH +: INPUT_FEATURES*DATA_WIDTH];
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]      current_Uh = i_Uh_flat[unit_idx*GRU_UNITS*DATA_WIDTH +: GRU_UNITS*DATA_WIDTH];
    wire [DATA_WIDTH-1:0]                  current_bh = i_bh_flat[unit_idx*DATA_WIDTH +: DATA_WIDTH];

    localparam S_IDLE            = 4'd0,
               S_START_R_UNIT    = 4'd1,
               S_WAIT_R_UNIT     = 4'd2,
               S_WAIT_R_ACK      = 4'd3,
               S_NEXT_R_UNIT     = 4'd4,
               S_MULT_R_H        = 4'd5,
               S_MULT_R_H_WAIT   = 4'd6,
               S_MULT_R_H_ACK    = 4'd7,
               S_START_ZH_UNIT   = 4'd8,
               S_WAIT_ZH_UNIT    = 4'd9,
               S_WAIT_ZH_ACK     = 4'd10,
               S_NEXT_ZH_UNIT    = 4'd11,
               S_DONE            = 4'd12;

    multiplier #(.DATA_WIDTH(DATA_WIDTH)) mult_inst (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_in1), .x(mult_in2), .mult_result(mult_out));

    GRU_Cell_BPTT #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES)) gru_cell (
        .clk(clk), .rstn(rstn), .i_start_cell(cell_start), .o_done_cell(cell_done),
        .i_computation_phase(computation_phase), .i_unit_idx(unit_idx),
        .i_input_vector_flat(i_input_vector_flat), .i_prev_hidden_state_flat(i_prev_hidden_state_flat),
        .i_r_modified_hidden_flat(r_modified_hidden),
        .i_Wr_flat(current_Wr), .i_Ur_flat(current_Ur), .i_br(current_br),
        .i_Wz_flat(current_Wz), .i_Uz_flat(current_Uz), .i_bz(current_bz),
        .i_Wh_flat(current_Wh), .i_Uh_flat(current_Uh), .i_bh(current_bh),
        .o_new_hidden_state(cell_output), .o_r_gate_cached(r_gate_out), .o_z_gate_cached(z_gate_out), .o_h_candidate_cached(h_cand_out)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 0; cell_start <= 0; mult_start <= 0;
            unit_idx <= 0; computation_phase <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_done <= 0; cell_start <= 0; mult_start <= 0;
                    if (i_start) begin
                        computation_phase <= 0;
                        unit_idx <= 0;
                        state <= S_START_R_UNIT;
                    end
                end

                S_START_R_UNIT: begin cell_start <= 1; state <= S_WAIT_R_UNIT; end
                S_WAIT_R_UNIT: begin
                    cell_start <= 1;
                    if (cell_done) begin
                        r_gates_collected[unit_idx*DATA_WIDTH +: DATA_WIDTH] <= cell_output;
                        o_r_gates_cached[unit_idx*DATA_WIDTH +: DATA_WIDTH] <= r_gate_out;
                        cell_start <= 0;
                        state <= S_WAIT_R_ACK;
                    end
                end
                S_WAIT_R_ACK: begin cell_start <= 0; if (!cell_done) state <= S_NEXT_R_UNIT; end
                
                S_NEXT_R_UNIT: begin
                    if (unit_idx == GRU_UNITS - 1) begin
                        mult_index <= 0;
                        state <= S_MULT_R_H;
                    end else begin
                        unit_idx <= unit_idx + 1;
                        state <= S_START_R_UNIT;
                    end
                end

                S_MULT_R_H: begin
                    if (mult_index < GRU_UNITS) begin
                        mult_in1 <= r_gates_collected[mult_index*DATA_WIDTH +: DATA_WIDTH];
                        mult_in2 <= i_prev_hidden_state_flat[mult_index*DATA_WIDTH +: DATA_WIDTH];
                        mult_start <= 1;
                        state <= S_MULT_R_H_WAIT;
                    end else begin
                        computation_phase <= 1;
                        unit_idx <= 0;
                        state <= S_START_ZH_UNIT;
                    end
                end
                S_MULT_R_H_WAIT: begin
                    if (mult_done) begin
                        r_modified_hidden[mult_index*DATA_WIDTH +: DATA_WIDTH] <= mult_out;
                        mult_start <= 0;
                        state <= S_MULT_R_H_ACK;
                    end else mult_start <= 1;
                end
                S_MULT_R_H_ACK: begin mult_start <= 0; if (!mult_done) begin mult_index <= mult_index + 1; state <= S_MULT_R_H; end end

                S_START_ZH_UNIT: begin cell_start <= 1; state <= S_WAIT_ZH_UNIT; end
                S_WAIT_ZH_UNIT: begin
                    cell_start <= 1;
                    if (cell_done) begin
                        new_hidden_state_buffer[unit_idx*DATA_WIDTH +: DATA_WIDTH] <= cell_output;
                        o_z_gates_cached[unit_idx*DATA_WIDTH +: DATA_WIDTH] <= z_gate_out;
                        o_h_candidates_cached[unit_idx*DATA_WIDTH +: DATA_WIDTH] <= h_cand_out;
                        cell_start <= 0;
                        state <= S_WAIT_ZH_ACK;
                    end
                end
                S_WAIT_ZH_ACK: begin cell_start <= 0; if (!cell_done) state <= S_NEXT_ZH_UNIT; end

                S_NEXT_ZH_UNIT: begin
                    if (unit_idx == GRU_UNITS - 1) begin
                        o_new_hidden_state_flat <= new_hidden_state_buffer;
                        state <= S_DONE;
                    end else begin
                        unit_idx <= unit_idx + 1;
                        state <= S_START_ZH_UNIT;
                    end
                end

                
                S_DONE: begin
                    o_done <= 1; 
                    if (!i_start) begin 
                        state <= S_IDLE; 
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule