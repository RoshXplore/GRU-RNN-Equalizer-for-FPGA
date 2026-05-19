`timescale 1ns / 1ps

module Training_Controller #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 2,
    parameter GRU_UNITS = 3,
    parameter SEQUENCE_LENGTH = 3,
    parameter OUTPUT_SIZE = 2,
    parameter BATCH_SIZE = 64
)(
    input wire clk,
    input wire rstn,
    
    input wire i_start,                
    input wire i_inference_mode,       
    output reg o_done,                 
    
    input wire [DATA_WIDTH-1:0] i_learning_rate,
    
    input wire [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] i_input_sequence_flat,
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_target_output_flat,
    
    // Weights Inputs
    input wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] i_Wr_flat,
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      i_Ur_flat,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]                i_br_flat,
    input wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] i_Wz_flat,
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      i_Uz_flat,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]                i_bz_flat,
    input wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] i_Wh_flat,
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      i_Uh_flat,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]                i_bh_flat,
    input wire [(GRU_UNITS*OUTPUT_SIZE*DATA_WIDTH)-1:0]    i_fc_weights_flat,
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0]              i_fc_bias_flat,
    
    // Gradient Outputs
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_ir,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hr,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_r,
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_iz,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hz,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_z,
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_in,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hn,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_n,
    output reg [(GRU_UNITS*OUTPUT_SIZE*DATA_WIDTH)-1:0]    o_grad_fc_weights,
    output reg [(OUTPUT_SIZE*DATA_WIDTH)-1:0]              o_grad_fc_bias,
    
    output reg o_clear_grads,
    output reg o_accum_grads,
    output reg o_update_weights_start,
    input wire i_updaters_done,
    input wire i_accumulators_done, 
    
    output reg [DATA_WIDTH-1:0] o_current_loss,
    output wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] o_prediction 
);

    // State Machine Definitions
    localparam S_IDLE              = 6'd0,
               S_CLEAR_GRADS       = 6'd1,
               S_CLEAR_GRADS_WAIT  = 6'd2,
               S_FWD_GRU_START     = 6'd3,
               S_FWD_GRU_WAIT      = 6'd4,
               S_FWD_GRU_ACK       = 6'd5,
               S_FWD_LINEAR_START  = 6'd6,
               S_FWD_LINEAR_WAIT   = 6'd7,
               S_FWD_LINEAR_ACK    = 6'd8,
               S_LOSS_START        = 6'd9,
               S_LOSS_WAIT         = 6'd10,
               S_LOSS_ACK          = 6'd11,
               S_BWD_LINEAR_START  = 6'd12,
               S_BWD_LINEAR_WAIT   = 6'd13,
               S_BWD_LINEAR_ACK    = 6'd14,
               S_BWD_LINEAR_ACCUM  = 6'd15,
               S_BWD_LINEAR_ACCUM_WAIT = 6'd16,
               S_BWD_GRU_START     = 6'd17,
               S_BWD_GRU_WAIT      = 6'd18,
               S_BWD_GRU_ACK       = 6'd19,
               S_BWD_GRU_ACCUM     = 6'd20,
               S_BWD_GRU_ACCUM_WAIT = 6'd21,
               S_UPDATE_START      = 6'd22,
               S_UPDATE_WAIT       = 6'd23,
               S_UPDATE_ACK        = 6'd24,
               S_DONE              = 6'd25;
               
    reg [5:0] state;
    reg [7:0] timestep_idx;
    integer k;
    
    reg [9:0] batch_counter;
    
    reg fwd_gru_start, fwd_linear_start, loss_start, bwd_linear_start, bwd_gru_start;
    wire fwd_gru_done, fwd_linear_done, loss_done, bwd_linear_done, bwd_gru_done;

    // Caches
    reg [(INPUT_FEATURES*DATA_WIDTH)-1:0] cache_x       [0:SEQUENCE_LENGTH-1];
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      cache_h_prev [0:SEQUENCE_LENGTH-1];
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      cache_r      [0:SEQUENCE_LENGTH-1];
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      cache_z      [0:SEQUENCE_LENGTH-1];
    reg [(GRU_UNITS*DATA_WIDTH)-1:0]      cache_n      [0:SEQUENCE_LENGTH-1];

    // Forward signals
    reg  [(INPUT_FEATURES*DATA_WIDTH)-1:0] fwd_gru_x_in;
    reg  [(GRU_UNITS*DATA_WIDTH)-1:0]      fwd_gru_h_prev;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]      fwd_gru_h_out, fwd_gru_r_out, fwd_gru_z_out, fwd_gru_n_out;
    reg  [(GRU_UNITS*DATA_WIDTH)-1:0]      fwd_linear_h_in;
    wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0]    fwd_linear_pred;
    
    // Backward signals
    wire [DATA_WIDTH-1:0]                  loss_val;
    wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0]    loss_grad;
    wire [(GRU_UNITS*OUTPUT_SIZE*DATA_WIDTH)-1:0] bwd_linear_grad_w;
    wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0]           bwd_linear_grad_b;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]             bwd_linear_grad_h;
    wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] bwd_gru_grad_W_ir, bwd_gru_grad_W_iz, bwd_gru_grad_W_in;
    wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      bwd_gru_grad_U_hr, bwd_gru_grad_U_hz, bwd_gru_grad_U_hn;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]                bwd_gru_grad_b_r, bwd_gru_grad_b_z, bwd_gru_grad_b_n;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]                bwd_gru_grad_h_prev;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] grad_h_next;
    
    assign o_prediction = fwd_linear_pred;

    // INSTANTIATION
    GRU_Layer_BPTT #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES)) fwd_gru_inst (
        .clk(clk), .rstn(rstn), .i_start(fwd_gru_start), .o_done(fwd_gru_done),
        .i_input_vector_flat(fwd_gru_x_in), .i_prev_hidden_state_flat(fwd_gru_h_prev),
        .i_Wr_flat(i_Wr_flat), .i_Ur_flat(i_Ur_flat), .i_br_flat(i_br_flat),
        .i_Wz_flat(i_Wz_flat), .i_Uz_flat(i_Uz_flat), .i_bz_flat(i_bz_flat),
        .i_Wh_flat(i_Wh_flat), .i_Uh_flat(i_Uh_flat), .i_bh_flat(i_bh_flat),
        .o_new_hidden_state_flat(fwd_gru_h_out), .o_r_gates_cached(fwd_gru_r_out),
        .o_z_gates_cached(fwd_gru_z_out), .o_h_candidates_cached(fwd_gru_n_out)
    );

    linear_layer #(.DATA_WIDTH(DATA_WIDTH), .INPUT_VECTOR_SIZE(GRU_UNITS), .OUTPUT_SIZE(OUTPUT_SIZE)) fwd_linear_inst (
        .clk(clk), .rstn(rstn), .i_start(fwd_linear_start), .o_done(fwd_linear_done),
        .i_input_vector_flat(fwd_linear_h_in), .i_fc_weights_flat(i_fc_weights_flat), .i_fc_bias_flat(i_fc_bias_flat),
        .o_final_prediction(fwd_linear_pred)
    );
    
    mse_loss #(.DATA_WIDTH(DATA_WIDTH), .OUTPUT_SIZE(OUTPUT_SIZE)) loss_inst (
        .clk(clk), .rstn(rstn), .i_start(loss_start), .o_done(loss_done),
        .i_prediction(fwd_linear_pred), .i_target(i_target_output_flat),
        .o_loss(loss_val), .o_gradient(loss_grad)
    );
    
    linear_layer_backward #(.DATA_WIDTH(DATA_WIDTH), .INPUT_SIZE(GRU_UNITS), .OUTPUT_SIZE(OUTPUT_SIZE)) bwd_linear_inst (
        .clk(clk), .rstn(rstn), .i_start(bwd_linear_start), .o_done(bwd_linear_done),
        .i_input_vector_flat(fwd_linear_h_in), .i_grad_output_flat(loss_grad),
        .i_fc_weights_flat(i_fc_weights_flat),
        .o_grad_weights_flat(bwd_linear_grad_w), .o_grad_bias_flat(bwd_linear_grad_b), .o_grad_input_flat(bwd_linear_grad_h)
    );
    
    GRU_Backward #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES)) bwd_gru_inst (
        .clk(clk), .rstn(rstn), .i_start(bwd_gru_start), .o_done(bwd_gru_done),
        .i_x_t(cache_x[timestep_idx]), .i_h_prev(cache_h_prev[timestep_idx]),
        .i_r_t(cache_r[timestep_idx]), .i_z_t(cache_z[timestep_idx]), .i_n_t(cache_n[timestep_idx]),
        .i_grad_h_t(grad_h_next),
        .i_U_hn(i_Uh_flat), .i_U_hr(i_Ur_flat), .i_U_hz(i_Uz_flat),
        .o_grad_W_ir(bwd_gru_grad_W_ir), .o_grad_U_hr(bwd_gru_grad_U_hr), .o_grad_b_r(bwd_gru_grad_b_r),
        .o_grad_W_iz(bwd_gru_grad_W_iz), .o_grad_U_hz(bwd_gru_grad_U_hz), .o_grad_b_z(bwd_gru_grad_b_z),
        .o_grad_W_in(bwd_gru_grad_W_in), .o_grad_U_hn(bwd_gru_grad_U_hn), .o_grad_b_n(bwd_gru_grad_b_n),
        .o_grad_h_prev(bwd_gru_grad_h_prev)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_done <= 0;
            o_clear_grads <= 0; o_accum_grads <= 0; o_update_weights_start <= 0;
            fwd_gru_start <= 0; fwd_linear_start <= 0; loss_start <= 0;
            bwd_linear_start <= 0; bwd_gru_start <= 0;
            timestep_idx <= 0;
            fwd_gru_h_prev <= 0;
            grad_h_next <= 0;
            o_current_loss <= 0;
            batch_counter <= 0;
            for (k = 0; k < SEQUENCE_LENGTH; k = k + 1) begin
                cache_x[k] <= 0; cache_h_prev[k] <= 0; cache_r[k] <= 0; cache_z[k] <= 0; cache_n[k] <= 0;
            end
            o_grad_W_ir <= 0; o_grad_U_hr <= 0; o_grad_b_r <= 0;
            o_grad_W_iz <= 0; o_grad_U_hz <= 0; o_grad_b_z <= 0;
            o_grad_W_in <= 0; o_grad_U_hn <= 0; o_grad_b_n <= 0;
            o_grad_fc_weights <= 0; o_grad_fc_bias <= 0;
            
        end else begin
            case (state)
                S_IDLE: begin
                    o_done <= 0;
                    o_clear_grads <= 0; o_accum_grads <= 0; o_update_weights_start <= 0;
                    if (i_start) begin
                        
                        if (batch_counter == 0) begin
                            o_clear_grads <= 1; // Signal trainer to clear
                            state <= S_CLEAR_GRADS_WAIT;
                        end else begin
                            
                            timestep_idx <= 0;
                            fwd_gru_h_prev <= 0;
                            state <= S_FWD_GRU_START;
                        end
                    end
                end

               
                
                S_CLEAR_GRADS_WAIT: begin
                    o_clear_grads <= 0;
                    timestep_idx <= 0;
                    fwd_gru_h_prev <= 0;
                    state <= S_FWD_GRU_START;
                end
                
                // FORWARD PASS
                S_FWD_GRU_START: begin
                    if (timestep_idx < SEQUENCE_LENGTH) begin
                        fwd_gru_x_in <= i_input_sequence_flat[timestep_idx*INPUT_FEATURES*DATA_WIDTH +: INPUT_FEATURES*DATA_WIDTH];
                        fwd_gru_start <= 1; 
                        state <= S_FWD_GRU_WAIT;
                    end else begin
                        state <= S_FWD_LINEAR_START;
                    end
                end
                
                S_FWD_GRU_WAIT: begin
                    fwd_gru_start <= 1; 
                    if (fwd_gru_done) begin
                        fwd_gru_start <= 0; 
                        
                        cache_x[timestep_idx] <= fwd_gru_x_in;
                        cache_h_prev[timestep_idx] <= fwd_gru_h_prev;
                        cache_r[timestep_idx] <= fwd_gru_r_out;
                        cache_z[timestep_idx] <= fwd_gru_z_out;
                        cache_n[timestep_idx] <= fwd_gru_n_out;
                        
                        fwd_gru_h_prev <= fwd_gru_h_out;
                        
                        state <= S_FWD_GRU_ACK;
                    end
                end
                
                S_FWD_GRU_ACK: begin
                    fwd_gru_start <= 0;
                    if (!fwd_gru_done) begin 
                        timestep_idx <= timestep_idx + 1;
                        state <= S_FWD_GRU_START;
                    end
                end
                
                S_FWD_LINEAR_START: begin
                    fwd_linear_h_in <= fwd_gru_h_prev;
                    fwd_linear_start <= 1;
                    state <= S_FWD_LINEAR_WAIT;
                end
                
                S_FWD_LINEAR_WAIT: begin
                    fwd_linear_start <= 1;
                    if (fwd_linear_done) begin
                        fwd_linear_start <= 0;
                        state <= S_FWD_LINEAR_ACK;
                    end
                end

                S_FWD_LINEAR_ACK: begin
                    fwd_linear_start <= 0;
                    if (!fwd_linear_done) begin
                        if (i_inference_mode) begin
                            state <= S_DONE;
                        end else begin
                            state <= S_LOSS_START;
                        end
                    end
                end
                
                // BACKWARD PASS
                S_LOSS_START: begin
                    loss_start <= 1;
                    state <= S_LOSS_WAIT;
                end
                
                S_LOSS_WAIT: begin
                    loss_start <= 1;
                    if (loss_done) begin
                        loss_start <= 0;
                        o_current_loss <= loss_val;
                        state <= S_LOSS_ACK;
                    end
                end

                S_LOSS_ACK: begin
                    loss_start <= 0;
                    if (!loss_done) begin
                        state <= S_BWD_LINEAR_START;
                    end
                end
                
                S_BWD_LINEAR_START: begin 
                    bwd_linear_start <= 1; 
                    state <= S_BWD_LINEAR_WAIT; 
                end

                S_BWD_LINEAR_WAIT: begin
                    bwd_linear_start <= 1;
                    if (bwd_linear_done) begin
                        bwd_linear_start <= 0;
                        grad_h_next <= bwd_linear_grad_h;
                        o_grad_fc_weights <= bwd_linear_grad_w;
                        o_grad_fc_bias <= bwd_linear_grad_b;
                        state <= S_BWD_LINEAR_ACK;
                    end
                end

                S_BWD_LINEAR_ACK: begin
                    bwd_linear_start <= 0;
                    if (!bwd_linear_done) begin
                        state <= S_BWD_LINEAR_ACCUM;
                    end
                end

                S_BWD_LINEAR_ACCUM: begin 
                    o_accum_grads <= 1;
                    state <= S_BWD_LINEAR_ACCUM_WAIT; 
                end

                S_BWD_LINEAR_ACCUM_WAIT: begin
                    o_accum_grads <= 1;
                    if (i_accumulators_done) begin
                        o_accum_grads <= 0;
                        
                        o_grad_fc_weights <= 0;
                        o_grad_fc_bias <= 0;

                        timestep_idx <= SEQUENCE_LENGTH - 1;
                        state <= S_BWD_GRU_START;
                    end
                end
                
                S_BWD_GRU_START: begin
                    bwd_gru_start <= 1;
                    state <= S_BWD_GRU_WAIT;
                end

                S_BWD_GRU_WAIT: begin
                    bwd_gru_start <= 1;
                    if (bwd_gru_done) begin
                        bwd_gru_start <= 0;
                        grad_h_next <= bwd_gru_grad_h_prev;
                        o_grad_W_in <= bwd_gru_grad_W_in; o_grad_U_hn <= bwd_gru_grad_U_hn; o_grad_b_n <= bwd_gru_grad_b_n;
                        o_grad_W_ir <= bwd_gru_grad_W_ir; o_grad_U_hr <= bwd_gru_grad_U_hr; o_grad_b_r <= bwd_gru_grad_b_r;
                        o_grad_W_iz <= bwd_gru_grad_W_iz; o_grad_U_hz <= bwd_gru_grad_U_hz; o_grad_b_z <= bwd_gru_grad_b_z;
                        state <= S_BWD_GRU_ACK;
                    end
                end

                S_BWD_GRU_ACK: begin
                    bwd_gru_start <= 0;
                    if (!bwd_gru_done) begin
                        state <= S_BWD_GRU_ACCUM;
                    end
                end

                S_BWD_GRU_ACCUM: begin 
                    o_accum_grads <= 1; 
                    state <= S_BWD_GRU_ACCUM_WAIT; 
                end

                S_BWD_GRU_ACCUM_WAIT: begin
                    o_accum_grads <= 1;
                    if (i_accumulators_done) begin
                        o_accum_grads <= 0;
                        
                        o_grad_W_in <= 0; o_grad_U_hn <= 0; o_grad_b_n <= 0;
                        o_grad_W_ir <= 0; o_grad_U_hr <= 0; o_grad_b_r <= 0;
                        o_grad_W_iz <= 0; o_grad_U_hz <= 0; o_grad_b_z <= 0;

                        if (timestep_idx == 0) begin
                            
                            if (batch_counter == BATCH_SIZE - 1) begin
                                batch_counter <= 0;
                                state <= S_UPDATE_START;
                            end else begin
                                batch_counter <= batch_counter + 1;
                                state <= S_DONE;
                            end
                        end else begin 
                            timestep_idx <= timestep_idx - 1; 
                            state <= S_BWD_GRU_START; 
                        end
                    end
                end
                
                S_UPDATE_START: begin 
                    o_update_weights_start <= 1; 
                    state <= S_UPDATE_WAIT; 
                end

                S_UPDATE_WAIT: begin
                    o_update_weights_start <= 1; 
                    if (i_updaters_done) begin
                        o_update_weights_start <= 0; 
                        state <= S_UPDATE_ACK; 
                    end
                end

                S_UPDATE_ACK: begin
                    o_update_weights_start <= 0;
                    if (!i_updaters_done) begin
                        state <= S_DONE;
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