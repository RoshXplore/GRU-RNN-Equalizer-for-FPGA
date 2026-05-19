`timescale 1ns / 1ps

module GRU_Cell_BPTT #(
    parameter DATA_WIDTH = 32,
    parameter GRU_UNITS = 3,
    parameter INPUT_FEATURES = 2
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_start_cell,
    output reg  o_done_cell,
    input  wire i_computation_phase,
    input  wire [7:0] i_unit_idx,
    
    input  wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] i_input_vector_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_prev_hidden_state_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_r_modified_hidden_flat,
    
    input  wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] i_Wr_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_Ur_flat,
    input  wire [DATA_WIDTH-1:0]                  i_br,
    input  wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] i_Wz_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_Uz_flat,
    input  wire [DATA_WIDTH-1:0]                  i_bz,
    input  wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] i_Wh_flat,
    input  wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_Uh_flat,
    input  wire [DATA_WIDTH-1:0]                  i_bh,
    
    output reg [DATA_WIDTH-1:0] o_new_hidden_state,
    output reg [DATA_WIDTH-1:0] o_r_gate_cached,
    output reg [DATA_WIDTH-1:0] o_z_gate_cached,
    output reg [DATA_WIDTH-1:0] o_h_candidate_cached
);

    localparam S_IDLE            = 5'd0,
               S_SETUP_R         = 5'd1,
               S_START_R         = 5'd2,
               S_WAIT_R          = 5'd3,
               S_SETUP_Z         = 5'd4,
               S_START_Z         = 5'd5,
               S_WAIT_Z          = 5'd6,
               S_SETUP_H         = 5'd7,
               S_START_H         = 5'd8,
               S_WAIT_H          = 5'd9,
               S_FINAL_SUB       = 5'd10,
               S_FINAL_SUB_WAIT  = 5'd11,
               S_FINAL_SUB_ACK   = 5'd12,
               S_FINAL_MUL1      = 5'd13,
               S_FINAL_MUL1_WAIT = 5'd14,
               S_FINAL_MUL1_ACK  = 5'd15,
               S_FINAL_MUL2      = 5'd16,
               S_FINAL_MUL2_WAIT = 5'd17,
               S_FINAL_MUL2_ACK  = 5'd18,
               S_FINAL_ADD       = 5'd19,
               S_FINAL_ADD_WAIT  = 5'd20,
               S_DONE            = 5'd21;
    reg [4:0] state;

    reg [DATA_WIDTH-1:0] r_gate, z_gate, h_cand;
    reg [DATA_WIDTH-1:0] temp_1mz, temp_term1, temp_term2;
    
    reg gate_start, mult_start, add_start, sub_start;
    wire gate_done, mult_done, add_done, sub_done;
    wire [DATA_WIDTH-1:0] gate_result, mult_out, add_out, sub_out;
    reg [DATA_WIDTH-1:0] mult_in1, mult_in2, add_in1, add_in2, sub_in1, sub_in2;
    reg act_type;
    reg [(INPUT_FEATURES*DATA_WIDTH)-1:0] W_flat;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      U_flat;
    reg [DATA_WIDTH-1:0]                  bias;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      hidden_to_use;

    gate_cal #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES)) GCU (
        .clk(clk), .rstn(rstn), .start(gate_start), .done(gate_done),
        .activation_type(act_type), .i_input_vector_flat(i_input_vector_flat), .i_hidden_vector_flat(hidden_to_use),
        .i_W_weights_flat(W_flat), .i_U_weights_flat(U_flat), .bias(bias), .gate_result(gate_result)
    );
    
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) MUL (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_in1), .x(mult_in2), .mult_result(mult_out));
    adder #(.DATA_WIDTH(DATA_WIDTH)) ADD (.clk(clk), .rstn(rstn), .start(add_start), .done(add_done), .value_in(add_in1), .bias(add_in2), .value_out(add_out));
    subtractor #(.DATA_WIDTH(DATA_WIDTH)) SUB (.clk(clk), .rstn(rstn), .start(sub_start), .done(sub_done), .value_a(sub_in1), .value_b(sub_in2), .value_out(sub_out));

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done_cell <= 0;
            o_new_hidden_state <= 0;
            gate_start <= 0; mult_start <= 0; add_start <= 0; sub_start <= 0;
            o_r_gate_cached <= 0; o_z_gate_cached <= 0; o_h_candidate_cached <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    gate_start <= 0; mult_start <= 0; add_start <= 0; sub_start <= 0;
                    o_done_cell <= 0;
                    if (i_start_cell) begin
                        // Phase 0: Calculate R gate only 
                        // Phase 1: Calculate Z and H 
                        if (i_computation_phase == 0) begin
                            state <= S_SETUP_R;
                        end else begin
                            state <= S_SETUP_Z;
                        end
                    end
                end

                S_SETUP_R: begin act_type <= 0; W_flat <= i_Wr_flat; U_flat <= i_Ur_flat; bias <= i_br; hidden_to_use <= i_prev_hidden_state_flat; state <= S_START_R; end
                S_START_R: begin gate_start <= 1; state <= S_WAIT_R; end
                S_WAIT_R: begin
                    if (gate_done) begin
                        r_gate <= gate_result; o_new_hidden_state <= gate_result; o_r_gate_cached <= gate_result;
                        gate_start <= 0; state <= S_DONE;
                    end else gate_start <= 1;
                end

                S_SETUP_Z: begin act_type <= 0; W_flat <= i_Wz_flat; U_flat <= i_Uz_flat; bias <= i_bz; hidden_to_use <= i_prev_hidden_state_flat; state <= S_START_Z; end
                S_START_Z: begin gate_start <= 1; state <= S_WAIT_Z; end
                S_WAIT_Z: begin
                    if (gate_done) begin
                        z_gate <= gate_result; o_z_gate_cached <= gate_result;
                        gate_start <= 0; state <= S_SETUP_H;
                    end else gate_start <= 1;
                end

                S_SETUP_H: begin act_type <= 1; W_flat <= i_Wh_flat; U_flat <= i_Uh_flat; bias <= i_bh; hidden_to_use <= i_r_modified_hidden_flat; state <= S_START_H; end
                S_START_H: begin gate_start <= 1; state <= S_WAIT_H; end
                S_WAIT_H: begin
                    if (gate_done) begin
                        h_cand <= gate_result; o_h_candidate_cached <= gate_result;
                        gate_start <= 0; state <= S_FINAL_SUB;
                    end else gate_start <= 1;
                end

                S_FINAL_SUB: begin sub_in1 <= 32'h3F800000; sub_in2 <= z_gate; sub_start <= 1; state <= S_FINAL_SUB_WAIT; end
                S_FINAL_SUB_WAIT: begin if (sub_done) begin temp_1mz <= sub_out; sub_start <= 0; state <= S_FINAL_SUB_ACK; end else sub_start <= 1; end
                S_FINAL_SUB_ACK: begin sub_start <= 0; if (!sub_done) state <= S_FINAL_MUL1; end
                
                S_FINAL_MUL1: begin mult_in1 <= temp_1mz; mult_in2 <= h_cand; mult_start <= 1; state <= S_FINAL_MUL1_WAIT; end
                S_FINAL_MUL1_WAIT: begin if (mult_done) begin temp_term1 <= mult_out; mult_start <= 0; state <= S_FINAL_MUL1_ACK; end else mult_start <= 1; end
                S_FINAL_MUL1_ACK: begin mult_start <= 0; if (!mult_done) state <= S_FINAL_MUL2; end
                
                S_FINAL_MUL2: begin mult_in1 <= z_gate; mult_in2 <= i_prev_hidden_state_flat[i_unit_idx*DATA_WIDTH +: DATA_WIDTH]; mult_start <= 1; state <= S_FINAL_MUL2_WAIT; end
                S_FINAL_MUL2_WAIT: begin if (mult_done) begin temp_term2 <= mult_out; mult_start <= 0; state <= S_FINAL_MUL2_ACK; end else mult_start <= 1; end
                S_FINAL_MUL2_ACK: begin mult_start <= 0; if (!mult_done) state <= S_FINAL_ADD; end
                
                S_FINAL_ADD: begin add_in1 <= temp_term1; add_in2 <= temp_term2; add_start <= 1; state <= S_FINAL_ADD_WAIT; end
                S_FINAL_ADD_WAIT: begin
                    if (add_done) begin 
                        o_new_hidden_state <= add_out; 
                        add_start <= 0; state <= S_DONE; 
                    end else add_start <= 1;
                end

                S_DONE: begin
                    o_done_cell <= 1;
                    if (!i_start_cell) begin 
                        state <= S_IDLE; 
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end


endmodule