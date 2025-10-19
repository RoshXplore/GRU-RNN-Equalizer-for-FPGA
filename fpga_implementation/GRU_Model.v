`timescale 1ns / 1ps

module GRU_Model #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 3,
    parameter GRU_UNITS = 3,
    parameter SEQUENCE_LENGTH = 3,
    parameter OUTPUT_SIZE = 1
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,
    
    input wire [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] i_sequence_flat,
    
    output reg [DATA_WIDTH-1:0] o_prediction
);

    // --- INTERNAL WEIGHT STORAGE ---
    reg [DATA_WIDTH-1:0] Wr_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Ur_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] br_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] Wz_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Uz_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bz_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] Wh_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Uh_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bh_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] fc_w_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] fc_b_mem [0:0];

    initial begin
        $readmemh("w_ir.mem", Wr_mem);
        $readmemh("u_hr.mem", Ur_mem);
        $readmemh("b_r.mem", br_mem);
        $readmemh("w_iz.mem", Wz_mem);
        $readmemh("u_hz.mem", Uz_mem);
        $readmemh("b_z.mem", bz_mem);
        $readmemh("w_in.mem", Wh_mem);
        $readmemh("u_hn.mem", Uh_mem);
        $readmemh("b_n.mem", bh_mem);
        $readmemh("fc_w.mem", fc_w_mem);
        $readmemh("fc_b.mem", fc_b_mem);
    end
    
    reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] Wr_flat;
    reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] Ur_flat;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] br_flat;
    reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] Wz_flat;
    reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] Uz_flat;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] bz_flat;
    reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] Wh_flat;
    reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] Uh_flat;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] bh_flat;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] fc_weights_flat;
    reg [DATA_WIDTH-1:0] fc_bias;
    
    integer i;
    reg weights_loaded;
    reg [1:0] load_counter;
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            weights_loaded <= 0;
            load_counter <= 0;
            // Initialize to zero to avoid X propagation
            Wr_flat <= 0;
            Ur_flat <= 0;
            br_flat <= 0;
            Wz_flat <= 0;
            Uz_flat <= 0;
            bz_flat <= 0;
            Wh_flat <= 0;
            Uh_flat <= 0;
            bh_flat <= 0;
            fc_weights_flat <= 0;
            fc_bias <= 0;
        end else if (!weights_loaded) begin
            // Load weights over multiple cycles for stability
            if (load_counter == 0) begin
                for (i = 0; i < GRU_UNITS*INPUT_FEATURES; i = i + 1) begin
                    Wr_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Wr_mem[i];
                    Wz_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Wz_mem[i];
                    Wh_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Wh_mem[i];
                end
                load_counter <= 1;
            end else if (load_counter == 1) begin
                for (i = 0; i < GRU_UNITS*GRU_UNITS; i = i + 1) begin
                    Ur_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Ur_mem[i];
                    Uz_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Uz_mem[i];
                    Uh_flat[i*DATA_WIDTH +: DATA_WIDTH] <= Uh_mem[i];
                end
                load_counter <= 2;
            end else if (load_counter == 2) begin
                for (i = 0; i < GRU_UNITS; i = i + 1) begin
                    br_flat[i*DATA_WIDTH +: DATA_WIDTH] <= br_mem[i];
                    bz_flat[i*DATA_WIDTH +: DATA_WIDTH] <= bz_mem[i];
                    bh_flat[i*DATA_WIDTH +: DATA_WIDTH] <= bh_mem[i];
                    fc_weights_flat[i*DATA_WIDTH +: DATA_WIDTH] <= fc_w_mem[i];
                end
                fc_bias <= fc_b_mem[0];
                load_counter <= 3;
            end else begin
                weights_loaded <= 1;
                $display("[%0t] GRU_Model: All weights loaded", $time);
            end
        end
    end

    // === State Machine ===
    localparam S_IDLE            = 4'd0,
               S_START_GRU       = 4'd1,
               S_WAIT_GRU        = 4'd2,
               S_WAIT_GRU_IDLE   = 4'd3,
               S_START_LINEAR    = 4'd4,
               S_WAIT_LINEAR     = 4'd5,
               S_WAIT_LINEAR_IDLE= 4'd6,
               S_DONE            = 4'd7;
    
    reg [3:0] state;
    
    // === Sequence Processing ===
    reg [7:0] seq_idx;
    
    // === Hidden State Management ===
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] hidden_state;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0] new_hidden_state;
    
    // === Control Signals ===
    reg gru_layer_start;
    wire gru_layer_done;
    reg linear_start;
    wire linear_done;
    
    // === Current Input Vector ===
    wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] current_input;
    assign current_input = i_sequence_flat[seq_idx*INPUT_FEATURES*DATA_WIDTH +: INPUT_FEATURES*DATA_WIDTH];
    
    // === GRU Layer Instance ===
    GRU_Layer #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES))
    gru_layer_inst (.clk(clk), .rstn(rstn), .i_start(gru_layer_start), .o_done(gru_layer_done),
        .i_input_vector_flat(current_input), .i_prev_hidden_state_flat(hidden_state),
        .i_Wr_flat(Wr_flat), .i_Ur_flat(Ur_flat), .i_br_flat(br_flat),
        .i_Wz_flat(Wz_flat), .i_Uz_flat(Uz_flat), .i_bz_flat(bz_flat),
        .i_Wh_flat(Wh_flat), .i_Uh_flat(Uh_flat), .i_bh_flat(bh_flat),
        .o_new_hidden_state_flat(new_hidden_state));
    
    // === Linear Layer Instance ===
    wire [DATA_WIDTH-1:0] linear_output;
    linear_layer #(.DATA_WIDTH(DATA_WIDTH), .INPUT_VECTOR_SIZE(GRU_UNITS))
    linear_layer_inst (.clk(clk), .rstn(rstn), .i_start(linear_start), .o_done(linear_done),
        .i_input_vector_flat(hidden_state), .i_fc_weights_flat(fc_weights_flat),
        .i_fc_bias(fc_bias), .o_final_prediction(linear_output));
		  
	initial begin
    $display("=== NEW GRU_Model.v LOADED ===");
end
    
    always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state <= S_IDLE;
        hidden_state <= 0;
        seq_idx <= 0;
        gru_layer_start <= 0;
        linear_start <= 0;
        o_done <= 0;
        o_prediction <= 0;
    end else begin
        case (state)
            S_IDLE: begin
                gru_layer_start <= 0;
                linear_start <= 0;
                o_done <= 0;
                
                if (i_start && weights_loaded) begin
                    $display("[%0t] GRU_Model: Starting inference", $time);
                    hidden_state <= 0;
                    seq_idx <= 0;
                    state <= S_START_GRU;
                end
            end
            
            S_START_GRU: begin
                $display("[%0t] GRU_Model: Processing timestep %0d/%0d", $time, seq_idx, SEQUENCE_LENGTH-1);
                gru_layer_start <= 1;
                state <= S_WAIT_GRU;
            end
            
            S_WAIT_GRU: begin
                gru_layer_start <= 1; // Keep start high
                if (gru_layer_done) begin
                    $display("[%0t] GRU_Model: GRU layer completed for timestep %0d", $time, seq_idx);
                    hidden_state <= new_hidden_state; // Latch new hidden state
                    gru_layer_start <= 0; // De-assert
                    state <= S_WAIT_GRU_IDLE;
                end
            end
            
            S_WAIT_GRU_IDLE: begin
                gru_layer_start <= 0;
                if (!gru_layer_done) begin // Wait for GRU to acknowledge
                    seq_idx <= seq_idx + 1;
                    if (seq_idx == SEQUENCE_LENGTH - 1) begin
                        $display("[%0t] GRU_Model: All timesteps processed, moving to linear layer", $time);
                        state <= S_START_LINEAR;
                    end else begin
                        state <= S_START_GRU; // Process next timestep
                    end
                end
            end

            S_START_LINEAR: begin
                $display("[%0t] GRU_Model: Starting linear layer", $time);
                linear_start <= 1;
                state <= S_WAIT_LINEAR;
            end

            S_WAIT_LINEAR: begin
                linear_start <= 1; // Keep start high
                if (linear_done) begin
                    $display("[%0t] GRU_Model: Linear layer completed", $time);
						  $display("[%0t] LINEAR DEBUG:", $time);
        $display("  Input h[0] = %h (%f)", hidden_state[31:0], $bitstoreal(hidden_state[31:0]));
        $display("  Input h[1] = %h (%f)", hidden_state[63:32], $bitstoreal(hidden_state[63:32]));
        $display("  Input h[2] = %h (%f)", hidden_state[95:64], $bitstoreal(hidden_state[95:64]));
        $display("  FC weight[0] = %h", fc_weights_flat[31:0]);
        $display("  FC weight[1] = %h", fc_weights_flat[63:32]);
        $display("  FC weight[2] = %h", fc_weights_flat[95:64]);
        $display("  FC bias = %h", fc_bias);
        $display("  Final prediction = %h (%f)", linear_output, $bitstoreal(linear_output));
                    o_prediction <= linear_output;
                    linear_start <= 0; // De-assert
                    state <= S_WAIT_LINEAR_IDLE;
                end
            end
            
            S_WAIT_LINEAR_IDLE: begin
                linear_start <= 0;
                if (!linear_done) begin
                    $display("[%0t] GRU_Model: Linear layer returned to idle, moving to DONE", $time);
                    state <= S_DONE;
                end
            end
            
            S_DONE: begin
                // Keep control signals stable
                gru_layer_start <= 0;
                linear_start <= 0;
                
                // Assert done and hold it
                if (!o_done) begin
                    // First clock in DONE state
                    o_done <= 1;
                    $display("[%0t] GRU_Model: Asserting o_done, prediction=%h", $time, o_prediction);
                end else begin
                    // Subsequent clocks in DONE state
                    o_done <= 1;  // Keep it high
                    
                    // Check if we should return to IDLE
                    if (!i_start) begin
                        $display("[%0t] GRU_Model: i_start dropped, returning to IDLE", $time);
                        o_done <= 0;
                        state <= S_IDLE;
                    end
                end
            end
            
            default: begin
                state <= S_IDLE;
            end
        endcase
    end
end
endmodule