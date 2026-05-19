
module fpga_top_module (
    input wire MAX10_CLK1_50,        
    input wire [1:0] KEY,            
    input wire [9:0] SW,             
    output wire [9:0] LEDR,
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);

   
    wire clk;
    wire pll_locked;
    PLLclk pll_inst (.inclk0(MAX10_CLK1_50), .c0(clk), .locked(pll_locked));

    reg [1:0] rstn_sync;
    wire global_rst_cond = KEY[0] && pll_locked;
    
    always @(posedge clk or negedge global_rst_cond) begin
        if (!global_rst_cond) 
            rstn_sync <= 2'b00;
        else 
            rstn_sync <= {rstn_sync[0], 1'b1};
    end
    wire rstn = rstn_sync[1];

   
    reg prev_sw0, prev_btn1;
    wire sw_start_edge = (SW[0] && !prev_sw0);
    wire btn_step_edge = (!KEY[1] && prev_btn1);
    always @(posedge clk) begin
        prev_sw0 <= SW[0];
        prev_btn1 <= KEY[1];
    end

    // ROM
    reg [14:0] rom_address;
    wire [31:0] rom_data;
    rom_new rom_inst (.address(rom_address), .clock(clk), .q(rom_data));

    localparam TOTAL_SAMPLES = 10;
    localparam DATA_WIDTH = 32;

    reg [3:0] state;
    reg [15:0] current_sample;
    reg [7:0] epoch;
    reg [2:0] load_cnt;
    reg [31:0] rom_buf [0:7];
    
    reg start_train;
    wire train_done;
    
    // SIGNAL TAP 
    (* keep = "true" *) wire [63:0] pred_out; 
    (* keep = "true" *) wire [31:0] loss;
    (* keep = "true" *) wire [7:0]  current_epoch_wire = epoch; 
    

    
    reg train_done_d;
    always @(posedge clk) train_done_d <= train_done;
    
    wire train_done_rising_edge = train_done && !train_done_d;
    

    (* keep = "true" *) wire epoch_capture_strobe = (train_done_rising_edge && (current_sample == TOTAL_SAMPLES - 1));
  
    reg [31:0] disp_loss, disp_pred_I, disp_pred_Q;

    //INFERENCE
    reg [63:0] i_targ;     
    reg [191:0] i_seq;     

    //LEARNING RATE
    reg [31:0] current_lr;
    
    always @(*) begin
        if (SW[1]) begin
            current_lr = 32'h00000000; // Inference Mode (LR=0)
        end else begin
            case(SW[3:2])
                
                2'b00: current_lr = 32'h3851B717; // 0.00005
                2'b01: current_lr = 32'h38D1B717; // 0.0001  
                2'b10: current_lr = 32'h3A03126F; // 0.0005  
                2'b11: current_lr = 32'h3A83126F; // 0.001  
            endcase
        end
    end

    //  DUT INSTANTIATION
    GRU_top #(
        .DATA_WIDTH(32), .INPUT_FEATURES(2), .GRU_UNITS(3), 
        .SEQUENCE_LENGTH(3), .OUTPUT_SIZE(2),
        .SAMPLES_PER_EPOCH(TOTAL_SAMPLES),
        .BATCH_SIZE(5), 
        .CLIP_VAL(32'h3F800000) 
    ) trainer (
        .clk(clk), .rstn(rstn), .i_start(start_train), 
        .i_inference_mode(SW[1]), 
        .o_done(train_done),
        .i_input_sequence_flat(i_seq),
        .i_target_output_flat(i_targ),
        .i_learning_rate(current_lr), 
        .o_current_loss(loss),
        .o_prediction(pred_out),
        .o_Wr_flat()
    );

    // states
    localparam FSM_IDLE=0, FSM_LOAD=1, FSM_WAIT_ROM=2, FSM_STORE=3, FSM_PACK=4, 
               FSM_TRAIN=5, FSM_WAIT_TR=6, FSM_NEXT=7, FSM_PAUSE=8;
    
    wire [14:0] mem_ptr = current_sample * 8;

    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            state <= FSM_IDLE;
            current_sample <= 0; epoch <= 0; load_cnt <= 0;
            start_train <= 0;
            disp_loss <= 0; disp_pred_I <= 0; disp_pred_Q <= 0;
        end else begin
            case(state)
                FSM_IDLE: if(sw_start_edge) begin 
                    current_sample=0; epoch=0; state<=FSM_LOAD; 
                end

                FSM_LOAD: begin 
                    rom_address <= mem_ptr + load_cnt; 
                    state <= FSM_WAIT_ROM; 
                end
                
                FSM_WAIT_ROM: state <= FSM_STORE;
                
                FSM_STORE: begin
                    rom_buf[load_cnt] <= rom_data;
                    if(load_cnt == 7) begin 
                        load_cnt<=0; state<=FSM_PACK; 
                    end else begin 
                        load_cnt<=load_cnt+1; state<=FSM_LOAD; 
                    end
                end
                
                FSM_PACK: begin
                    i_targ <= {rom_buf[1], rom_buf[0]};
                    i_seq  <= {rom_buf[7], rom_buf[6], rom_buf[5], rom_buf[4], rom_buf[3], rom_buf[2]};
                    state <= FSM_TRAIN;
                end
                
                FSM_TRAIN: begin 
                    start_train <= 1; 
                    state <= FSM_WAIT_TR; 
                end
                
                FSM_WAIT_TR: if(train_done) begin 
                    start_train <= 0; 
                    
                    
                    if (current_sample == TOTAL_SAMPLES - 1) begin
                        disp_loss   <= loss;
                        disp_pred_I <= pred_out[31:0];
                        disp_pred_Q <= pred_out[63:32];
                    end
                    
                    state <= FSM_NEXT; 
                end

                FSM_NEXT: begin
                    if(current_sample < TOTAL_SAMPLES-1) begin
                        current_sample <= current_sample + 1;
                        state <= FSM_LOAD;
                    end else begin
                        state <= FSM_PAUSE;
                    end
                end
                
                FSM_PAUSE: begin
                    if(btn_step_edge || SW[9]) begin
                        epoch <= epoch + 1;
                        current_sample <= 0;
                        state <= FSM_LOAD;
                    end
                end
            endcase
        end
    end

    //LEDS ---
    assign LEDR[9] = (state != FSM_IDLE); 
    assign LEDR[8] = epoch_capture_strobe; 
    assign LEDR[7:0] = epoch[7:0]; 

    // 7-SEG DISPLAY 
    reg [31:0] debug_val;
    always @(*) begin
        case(SW[6:4]) 
            3'b000: debug_val = disp_loss;          
            3'b001: debug_val = disp_pred_I;        
            3'b010: debug_val = disp_pred_Q;        
            3'b011: debug_val = {24'h0, epoch};     
            3'b100: debug_val = loss;               
            default: debug_val = 32'hFFFFFFFF;
        endcase
    end

    // Use SW[7] to toggle Hex High/Low
    wire [23:0] hex_val = SW[7] ? debug_val[31:8] : debug_val[23:0];
    
    seven_seg_decoder h0(hex_val[3:0], HEX0);
    seven_seg_decoder h1(hex_val[7:4], HEX1);
    seven_seg_decoder h2(hex_val[11:8], HEX2);
    seven_seg_decoder h3(hex_val[15:12], HEX3);
    seven_seg_decoder h4(hex_val[19:16], HEX4);
    seven_seg_decoder h5(hex_val[23:20], HEX5);

endmodule


module seven_seg_decoder(input [3:0] digit, output reg [7:0] seg);
    always @(*) case(digit)
        0: seg = 8'b11000000; 1: seg = 8'b11111001; 2: seg = 8'b10100100; 3: seg = 8'b10110000;
        4: seg = 8'b10011001; 5: seg = 8'b10010010; 6: seg = 8'b10000010; 7: seg = 8'b11111000;
        8: seg = 8'b10000000; 9: seg = 8'b10010000; 
        10: seg = 8'b10001000; 11: seg = 8'b10000011; 12: seg = 8'b11000110; 
        13: seg = 8'b10100001; 14: seg = 8'b10000110; 15: seg = 8'b10001110;
        default: seg = 8'b11111111;
    endcase
endmodule