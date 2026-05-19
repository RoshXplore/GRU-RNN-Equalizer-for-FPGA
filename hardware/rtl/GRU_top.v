`timescale 1ns / 1ps

module GRU_top #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 2,
    parameter GRU_UNITS = 3,
    parameter SEQUENCE_LENGTH = 3,
    parameter OUTPUT_SIZE = 2,
    parameter BATCH_SIZE = 64,
    parameter CLIP_VAL = 32'h3F800000, 
    parameter SAMPLES_PER_EPOCH = 3500 
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    input wire i_inference_mode,
    output reg o_done,
    
    input wire [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] i_input_sequence_flat,
    input wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_target_output_flat,
    input wire [DATA_WIDTH-1:0] i_learning_rate,
    
    output wire [DATA_WIDTH-1:0] o_current_loss,
    output wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] o_prediction,
    
    // Weight Outputs
    output wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_Wr_flat,
    output wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_Ur_flat,
    output wire [(GRU_UNITS*DATA_WIDTH)-1:0]                o_br_flat,
    output wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_Wz_flat,
    output wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_Uz_flat,
    output wire [(GRU_UNITS*DATA_WIDTH)-1:0]                o_bz_flat,
    output wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_Wh_flat,
    output wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_Uh_flat,
    output wire [(GRU_UNITS*DATA_WIDTH)-1:0]                o_bh_flat,
    output wire [(GRU_UNITS*OUTPUT_SIZE*DATA_WIDTH)-1:0]    o_fc_weights_flat,
    output wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0]              o_fc_bias_flat
);

    // Parameter Sizes 
    localparam SIZE_W    = INPUT_FEATURES * GRU_UNITS;
    localparam SIZE_U    = GRU_UNITS * GRU_UNITS;
    localparam SIZE_B    = GRU_UNITS;
    localparam SIZE_FC_W = GRU_UNITS * OUTPUT_SIZE;
    localparam SIZE_FC_B = OUTPUT_SIZE;

    // Registers
    reg [(SIZE_W*DATA_WIDTH)-1:0]    Wr_flat, Wz_flat, Wh_flat;
    reg [(SIZE_U*DATA_WIDTH)-1:0]    Ur_flat, Uz_flat, Uh_flat;
    reg [(SIZE_B*DATA_WIDTH)-1:0]    br_flat, bz_flat, bh_flat;
    reg [(SIZE_FC_W*DATA_WIDTH)-1:0] fc_weights_flat;
    reg [(SIZE_FC_B*DATA_WIDTH)-1:0] fc_bias_flat;

    reg [(SIZE_W*DATA_WIDTH)-1:0]    accum_grad_Wr, accum_grad_Wz, accum_grad_Wh;
    reg [(SIZE_U*DATA_WIDTH)-1:0]    accum_grad_Ur, accum_grad_Uz, accum_grad_Uh;
    reg [(SIZE_B*DATA_WIDTH)-1:0]    accum_grad_br, accum_grad_bz, accum_grad_bh;
    reg [(SIZE_FC_W*DATA_WIDTH)-1:0] accum_grad_fc_w;
    reg [(SIZE_FC_B*DATA_WIDTH)-1:0] accum_grad_fc_b;

    // --- Wire Definitions ---
    wire [(SIZE_W*DATA_WIDTH)-1:0]    grad_Wr, grad_Wz, grad_Wh;
    wire [(SIZE_U*DATA_WIDTH)-1:0]    grad_Ur, grad_Uz, grad_Uh;
    wire [(SIZE_B*DATA_WIDTH)-1:0]    grad_br, grad_bz, grad_bh;
    wire [(SIZE_FC_W*DATA_WIDTH)-1:0] grad_fc_w;
    wire [(SIZE_FC_B*DATA_WIDTH)-1:0] grad_fc_b;

    wire clear_grads, accum_grads, update_weights_start, ctrl_done;
    
    // Arithmetic Signals
    reg [DATA_WIDTH-1:0] mult_in_a, mult_in_b, sub_in_a, sub_in_b, add_in_a, add_in_b;
    reg mult_start, sub_start, add_start, clip_start;
    wire [DATA_WIDTH-1:0] scaled_grad, updated_weight, add_result, clipped_grad_out;
    wire mult_done, sub_done, add_done, clip_done;
    
    //  Multiplexed Signals 
    reg [DATA_WIDTH-1:0] current_accum_grad, incoming_grad;
    reg [DATA_WIDTH-1:0] sgd_weight_in, sgd_grad_in;
    reg [11:0] current_limit;
    reg [11:0] elem_idx;
    reg [3:0] param_id;
    reg op_done_sig;

    // LFSR Signals for Random Init 
    reg [31:0] lfsr_reg;
    reg [DATA_WIDTH-1:0] rnd_float;
    
  
    reg weights_initialized;

    // Output Assignments 
    assign o_Wr_flat = Wr_flat; assign o_Ur_flat = Ur_flat; assign o_br_flat = br_flat;
    assign o_Wz_flat = Wz_flat; assign o_Uz_flat = Uz_flat; assign o_bz_flat = bz_flat;
    assign o_Wh_flat = Wh_flat; assign o_Uh_flat = Uh_flat; assign o_bh_flat = bh_flat;
    assign o_fc_weights_flat = fc_weights_flat; assign o_fc_bias_flat = fc_bias_flat;

    //Submodules 
    Training_Controller #(
        .DATA_WIDTH(DATA_WIDTH), .INPUT_FEATURES(INPUT_FEATURES), .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH), .OUTPUT_SIZE(OUTPUT_SIZE),
        .BATCH_SIZE(BATCH_SIZE)
    ) ctrl (
        .clk(clk), .rstn(rstn),
        .i_start(i_start), .i_inference_mode(i_inference_mode), .o_done(ctrl_done),
        .i_learning_rate(i_learning_rate),
        .i_input_sequence_flat(i_input_sequence_flat), .i_target_output_flat(i_target_output_flat),
        .i_Wr_flat(Wr_flat), .i_Ur_flat(Ur_flat), .i_br_flat(br_flat),
        .i_Wz_flat(Wz_flat), .i_Uz_flat(Uz_flat), .i_bz_flat(bz_flat),
        .i_Wh_flat(Wh_flat), .i_Uh_flat(Uh_flat), .i_bh_flat(bh_flat),
        .i_fc_weights_flat(fc_weights_flat), .i_fc_bias_flat(fc_bias_flat),
        .o_grad_W_ir(grad_Wr), .o_grad_U_hr(grad_Ur), .o_grad_b_r(grad_br),
        .o_grad_W_iz(grad_Wz), .o_grad_U_hz(grad_Uz), .o_grad_b_z(grad_bz),
        .o_grad_W_in(grad_Wh), .o_grad_U_hn(grad_Uh), .o_grad_b_n(grad_bh),
        .o_grad_fc_weights(grad_fc_w), .o_grad_fc_bias(grad_fc_b),
        .o_clear_grads(clear_grads), .o_accum_grads(accum_grads), .o_update_weights_start(update_weights_start),
        .i_updaters_done(op_done_sig), .i_accumulators_done(op_done_sig),
        .o_current_loss(o_current_loss), .o_prediction(o_prediction)
    );

    multiplier #(.DATA_WIDTH(DATA_WIDTH)) mult_inst (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_in_a), .x(mult_in_b), .mult_result(scaled_grad));
    subtractor #(.DATA_WIDTH(DATA_WIDTH)) sub_inst  (.clk(clk), .rstn(rstn), .start(sub_start), .done(sub_done), .value_a(sub_in_a), .value_b(sub_in_b), .value_out(updated_weight));
    adder #(.DATA_WIDTH(DATA_WIDTH))      add_inst  (.clk(clk), .rstn(rstn), .start(add_start), .done(add_done), .value_in(add_in_a), .bias(add_in_b), .value_out(add_result));
    
    gradient_clipper #(.DATA_WIDTH(DATA_WIDTH)) clipper_inst (
        .clk(clk), .rstn(rstn), .i_start(clip_start), .o_done(clip_done),
        .i_gradient(incoming_grad), .i_clip_threshold(CLIP_VAL), .o_clipped_gradient(clipped_grad_out)
    );

    always @(*) begin
        case(param_id)
            0,3,6:   current_limit = SIZE_W;
            1,4,7:   current_limit = SIZE_U;
            2,5,8:   current_limit = SIZE_B;
            9:       current_limit = SIZE_FC_W;
            10:      current_limit = SIZE_FC_B;
            default: current_limit = 0;
        endcase
    end

    // MUX for Accumulation
    always @(*) begin
        incoming_grad = 0; current_accum_grad = 0;
        case(param_id)
            0: begin incoming_grad = grad_Wr[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Wr[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            1: begin incoming_grad = grad_Ur[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Ur[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            2: begin incoming_grad = grad_br[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_br[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            3: begin incoming_grad = grad_Wz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Wz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            4: begin incoming_grad = grad_Uz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Uz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            5: begin incoming_grad = grad_bz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_bz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            6: begin incoming_grad = grad_Wh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Wh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            7: begin incoming_grad = grad_Uh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_Uh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            8: begin incoming_grad = grad_bh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_bh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            9: begin incoming_grad = grad_fc_w[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_fc_w[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            10:begin incoming_grad = grad_fc_b[elem_idx*DATA_WIDTH +: DATA_WIDTH]; current_accum_grad = accum_grad_fc_b[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
        endcase
    end

    // MUX for SGD Update
    always @(*) begin
        sgd_weight_in = 0; sgd_grad_in = 0;
        case(param_id)
            0: begin sgd_weight_in = Wr_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Wr[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            1: begin sgd_weight_in = Ur_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Ur[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            2: begin sgd_weight_in = br_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_br[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            3: begin sgd_weight_in = Wz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Wz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            4: begin sgd_weight_in = Uz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Uz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            5: begin sgd_weight_in = bz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_bz[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            6: begin sgd_weight_in = Wh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Wh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            7: begin sgd_weight_in = Uh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_Uh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            8: begin sgd_weight_in = bh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_bh[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            9: begin sgd_weight_in = fc_weights_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_fc_w[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
            10:begin sgd_weight_in = fc_bias_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH]; sgd_grad_in = accum_grad_fc_b[elem_idx*DATA_WIDTH +: DATA_WIDTH]; end
        endcase
    end

    // Main State Machine 
    localparam SEQ_INIT         = 0,
               SEQ_IDLE         = 1, 
               SEQ_CLR          = 2,
               SEQ_ACCUMULATE   = 3, SEQ_CLIP_START = 4, SEQ_CLIP_WAIT = 5,
               SEQ_ACCUM_ADD    = 6, SEQ_ACCUM_WAIT = 7, SEQ_ACCUM_ACK = 8,
               SEQ_PROCESS      = 9, SEQ_MUL_START = 10, SEQ_MUL_WAIT = 11, SEQ_MUL_ACK = 12,
               SEQ_SUB_START    = 13, SEQ_SUB_WAIT = 14, SEQ_SUB_ACK = 15,
               SEQ_CLR_AFTER_UPDATE = 16, SEQ_DONE_ST = 17;
    
    reg [4:0] seq_state;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            seq_state <= SEQ_INIT;
            o_done <= 0; op_done_sig <= 0;
            param_id <= 0; elem_idx <= 0;
            mult_start <= 0; sub_start <= 0; add_start <= 0; clip_start <= 0;
            
            accum_grad_Wr <= 0; accum_grad_Ur <= 0; accum_grad_br <= 0;
            accum_grad_Wz <= 0; accum_grad_Uz <= 0; accum_grad_bz <= 0;
            accum_grad_Wh <= 0; accum_grad_Uh <= 0; accum_grad_bh <= 0;
            accum_grad_fc_w <= 0; accum_grad_fc_b <= 0;
            
            lfsr_reg <= 32'hACE1ACE1;
            weights_initialized <= 0; 

        end else begin
            o_done <= ctrl_done;

            case(seq_state)
            
                // WEIGHT INITIALIZATION STATE 
                SEQ_INIT: begin
                   
                    if (!weights_initialized) begin
                        // LFSR Shift
                        lfsr_reg <= {lfsr_reg[30:0], lfsr_reg[31] ^ lfsr_reg[21] ^ lfsr_reg[1] ^ lfsr_reg[0]};
                        
                        // Generate Random Float
                        rnd_float = {lfsr_reg[0], 8'h7C, lfsr_reg[23:1]};
                        
                        // Assign to Registers
                        if (elem_idx < current_limit) begin
                            case(param_id)
                                0: Wr_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                1: Ur_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                2: br_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                3: Wz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                4: Uz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                5: bz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                6: Wh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                7: Uh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                8: bh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                9: fc_weights_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                                10:fc_bias_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= rnd_float;
                            endcase
                            elem_idx <= elem_idx + 1;
                        end else begin
                            if (param_id == 10) begin
                                param_id <= 0;
                                elem_idx <= 0;
                                weights_initialized <= 1; 
                                seq_state <= SEQ_IDLE;
                            end else begin
                                param_id <= param_id + 1;
                                elem_idx <= 0;
                            end
                        end
                    end else begin
                       
                        seq_state <= SEQ_IDLE;
                    end
                end

                SEQ_IDLE: begin
                    
                    if (weights_initialized) begin
                        op_done_sig <= 0; param_id <= 0; elem_idx <= 0;
                        
                        
                        if (clear_grads) begin
                            seq_state <= SEQ_CLR;
                        end else if (accum_grads) begin
                            seq_state <= SEQ_ACCUMULATE;
                        end else if (update_weights_start) begin
                            seq_state <= SEQ_PROCESS;
                        end
                    end
                end

                SEQ_CLR: begin
                    accum_grad_Wr <= 0; accum_grad_Ur <= 0; accum_grad_br <= 0;
                    accum_grad_Wz <= 0; accum_grad_Uz <= 0; accum_grad_bz <= 0;
                    accum_grad_Wh <= 0; accum_grad_Uh <= 0; accum_grad_bh <= 0;
                    accum_grad_fc_w <= 0; accum_grad_fc_b <= 0;
                    
                    
                    if(!clear_grads) seq_state <= SEQ_IDLE;
                end

                
                SEQ_ACCUMULATE: begin
                    if (elem_idx < current_limit) seq_state <= SEQ_CLIP_START;
                    else begin
                        if (param_id == 10) begin
                            op_done_sig <= 1; seq_state <= SEQ_DONE_ST;
                        end else begin
                            param_id <= param_id + 1; elem_idx <= 0;
                        end
                    end
                end

                SEQ_CLIP_START: begin
                    clip_start <= 1; seq_state <= SEQ_CLIP_WAIT;
                end

                SEQ_CLIP_WAIT: begin
                    clip_start <= 1;
                    if (clip_done) begin
                        clip_start <= 0; seq_state <= SEQ_ACCUM_ADD;
                    end
                end

                SEQ_ACCUM_ADD: begin
                    add_in_a <= current_accum_grad; add_in_b <= clipped_grad_out;
                    add_start <= 1; seq_state <= SEQ_ACCUM_WAIT;
                end

                SEQ_ACCUM_WAIT: begin
                    add_start <= 1;
                    if (add_done) begin
                        add_start <= 0;
                        case(param_id)
                            0: accum_grad_Wr[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            1: accum_grad_Ur[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            2: accum_grad_br[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            3: accum_grad_Wz[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            4: accum_grad_Uz[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            5: accum_grad_bz[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            6: accum_grad_Wh[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            7: accum_grad_Uh[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            8: accum_grad_bh[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            9: accum_grad_fc_w[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            10:accum_grad_fc_b[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                        endcase
                        seq_state <= SEQ_ACCUM_ACK;
                    end
                end

                SEQ_ACCUM_ACK: begin
                    add_start <= 0;
                    if (!add_done) begin
                        elem_idx <= elem_idx + 1; seq_state <= SEQ_ACCUMULATE;
                    end
                end

                // Update Loop
                SEQ_PROCESS: begin
                    if (elem_idx < current_limit) seq_state <= SEQ_MUL_START;
                    else begin
                        if (param_id == 10) seq_state <= SEQ_CLR_AFTER_UPDATE;
                        else begin
                            param_id <= param_id + 1; elem_idx <= 0;
                        end
                    end
                end

                SEQ_MUL_START: begin
                    mult_in_a <= i_learning_rate; mult_in_b <= sgd_grad_in;
                    mult_start <= 1; seq_state <= SEQ_MUL_WAIT;
                end
                
                SEQ_MUL_WAIT: begin
                    mult_start <= 1;
                    if(mult_done) begin
                         mult_start <= 0; seq_state <= SEQ_MUL_ACK;
                    end
                end

                SEQ_MUL_ACK: begin
                    mult_start <= 0;
                    if(!mult_done) seq_state <= SEQ_SUB_START;
                end

                SEQ_SUB_START: begin
                    sub_in_a <= sgd_weight_in; sub_in_b <= scaled_grad;
                    sub_start <= 1; seq_state <= SEQ_SUB_WAIT;
                end

                SEQ_SUB_WAIT: begin
                    sub_start <= 1;
                    if(sub_done) begin
                        sub_start <= 0; seq_state <= SEQ_SUB_ACK;
                    end
                end

                SEQ_SUB_ACK: begin
                    sub_start <= 0;
                    if(!sub_done) begin
                         case(param_id)
                            0: Wr_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            1: Ur_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            2: br_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            3: Wz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            4: Uz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            5: bz_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            6: Wh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            7: Uh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            8: bh_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            9: fc_weights_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                            10:fc_bias_flat[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= updated_weight;
                        endcase
                        elem_idx <= elem_idx + 1; seq_state <= SEQ_PROCESS;
                    end
                end

                SEQ_CLR_AFTER_UPDATE: begin
                    accum_grad_Wr <= 0; accum_grad_Ur <= 0; accum_grad_br <= 0;
                    accum_grad_Wz <= 0; accum_grad_Uz <= 0; accum_grad_bz <= 0;
                    accum_grad_Wh <= 0; accum_grad_Uh <= 0; accum_grad_bh <= 0;
                    accum_grad_fc_w <= 0; accum_grad_fc_b <= 0;
                    op_done_sig <= 1; seq_state <= SEQ_DONE_ST;
                end

                SEQ_DONE_ST: begin
                    op_done_sig <= 1;
                    if (!accum_grads && !update_weights_start) begin
                        op_done_sig <= 0; param_id <= 0; elem_idx <= 0;
                        seq_state <= SEQ_IDLE;
                    end
                end
            endcase
        end
    end

    // Debug Probe
    integer dbg_epoch = 0;
    integer dbg_sample = 0;
    reg prev_update_start;
    reg prev_done;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dbg_epoch <= 0;
            dbg_sample <= 0;
            prev_update_start <= 0;
            prev_done <= 0;
        end else begin
            prev_update_start <= update_weights_start;
            prev_done <= o_done;

            if (o_done && !prev_done) begin
                if (dbg_sample == SAMPLES_PER_EPOCH - 1) begin 
                    dbg_sample <= 0;
                    dbg_epoch <= dbg_epoch + 1;
                end else begin
                    dbg_sample <= dbg_sample + 1;
                end
            end
        end
    end

endmodule