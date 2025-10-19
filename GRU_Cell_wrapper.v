`timescale 1ns/1ps

module GRU_Cell_wrapper #(
    parameter DATA_WIDTH = 32,
    parameter GRU_UNITS = 3,
    parameter INPUT_FEATURES = 3,
    parameter SEQ_LENGTH = 4
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_uart_rx,
    output reg  o_uart_tx,
    output reg  o_done_seq
);

    // --- Main FSM States ---
    localparam S_IDLE = 3'd0, S_RECEIVE = 3'd1, S_PROCESS_GRU = 3'd2, S_SEND_DATA = 3'd3, S_DONE = 3'd4;
    reg [2:0] state, next_state;

    // --- Data Parameters ---
    localparam INPUT_SEQ_WORDS = SEQ_LENGTH * INPUT_FEATURES;
    localparam W_WORDS = INPUT_FEATURES;
    localparam U_WORDS = GRU_UNITS;
    localparam B_WORDS = 1;
    localparam TOTAL_WORDS = INPUT_SEQ_WORDS + 3*(W_WORDS) + 3*(U_WORDS) + 3*(B_WORDS);
    localparam TOTAL_BYTES = TOTAL_WORDS * 4;
    localparam HIDDEN_SEQ_WORDS = SEQ_LENGTH * GRU_UNITS;
    localparam HIDDEN_SEQ_BYTES = HIDDEN_SEQ_WORDS * 4;
    localparam CLKS_PER_BIT = 10417;

    // --- Internal RAMs and Result Register ---
    reg [DATA_WIDTH-1:0] input_sequence_ram [0:INPUT_SEQ_WORDS-1];
    reg [DATA_WIDTH-1:0] Wr_ram [0:W_WORDS-1], Ur_ram [0:U_WORDS-1], br_ram [0:B_WORDS-1];
    reg [DATA_WIDTH-1:0] Wz_ram [0:W_WORDS-1], Uz_ram [0:U_WORDS-1], bz_ram [0:B_WORDS-1];
    reg [DATA_WIDTH-1:0] Wh_ram [0:W_WORDS-1], Uh_ram [0:U_WORDS-1], bh_ram [0:B_WORDS-1];
    reg [(HIDDEN_SEQ_WORDS*DATA_WIDTH)-1:0] hidden_sequence_reg;

    // --- UART Receiver ---
    reg rx_done; reg [7:0] rx_data;
    localparam RX_IDLE = 3'd0, RX_START = 3'd1, RX_DATA = 3'd2, RX_STOP = 3'd3, RX_DONE = 3'd4;
    reg [2:0] rx_state; reg [13:0] rx_clk_count; reg [3:0] rx_bit_idx; reg [7:0] rx_data_buf;
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin rx_state<=RX_IDLE; rx_done<=0; rx_clk_count<=0; rx_bit_idx<=0; end
        else begin rx_done<=0; case(rx_state)
            RX_IDLE: if(!i_uart_rx) begin rx_clk_count<=0; rx_state<=RX_START; end
            RX_START: if(rx_clk_count==(CLKS_PER_BIT/2)-1) begin rx_clk_count<=0; rx_bit_idx<=0; rx_state<=RX_DATA; end else rx_clk_count<=rx_clk_count+1;
            RX_DATA: if(rx_clk_count==CLKS_PER_BIT-1) begin rx_clk_count<=0; rx_data_buf[rx_bit_idx]<=i_uart_rx; if(rx_bit_idx==7) rx_state<=RX_STOP; else rx_bit_idx<=rx_bit_idx+1; end else rx_clk_count<=rx_clk_count+1;
            RX_STOP: if(rx_clk_count==CLKS_PER_BIT-1) begin rx_clk_count<=0; rx_state<=RX_DONE; end else rx_clk_count<=rx_clk_count+1;
            RX_DONE: begin rx_data<=rx_data_buf; rx_done<=1; rx_state<=RX_IDLE; end
        endcase end
    end

    // --- UART Transmitter ---
    reg tx_start; reg [7:0] tx_data; wire tx_busy;
    localparam TX_IDLE = 3'd0, TX_START = 3'd1, TX_DATA = 3'd2, TX_STOP = 3'd3;
    reg [2:0] tx_state; reg [13:0] tx_clk_count; reg [3:0] tx_bit_idx; reg [8:0] tx_buf;
    assign tx_busy = (tx_state != TX_IDLE);
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin tx_state<=TX_IDLE; o_uart_tx<=1; tx_clk_count<=0; end
        else begin case(tx_state)
            TX_IDLE: begin o_uart_tx<=1; if(tx_start) begin tx_buf<={tx_data,1'b1}; tx_clk_count<=0; tx_state<=TX_START; end end
            TX_START: begin o_uart_tx<=0; if(tx_clk_count==CLKS_PER_BIT-1) begin tx_clk_count<=0; tx_bit_idx<=0; tx_state<=TX_DATA; end else tx_clk_count<=tx_clk_count+1; end
            TX_DATA: begin o_uart_tx<=tx_buf[tx_bit_idx]; if(tx_clk_count==CLKS_PER_BIT-1) begin tx_clk_count<=0; if(tx_bit_idx==7) tx_state<=TX_STOP; else tx_bit_idx<=tx_bit_idx+1; end else tx_clk_count<=tx_clk_count+1; end
            TX_STOP: begin o_uart_tx<=1; if(tx_clk_count==CLKS_PER_BIT-1) tx_state<=TX_IDLE; else tx_clk_count<=tx_clk_count+1; end
        endcase end
    end

    // --- GRU Cell Instantiation and Logic ---
    reg cell_start; wire cell_done; wire [(GRU_UNITS*DATA_WIDTH)-1:0] cell_new_hidden;
    reg [(INPUT_FEATURES*DATA_WIDTH)-1:0] curr_input_vector; reg [(GRU_UNITS*DATA_WIDTH)-1:0] curr_hidden;
    reg [31:0] seq_idx; localparam P_IDLE=0, P_CELL=1, P_WAIT=2, P_DONE=3; reg [1:0] proc_state;
    integer i; reg [(INPUT_FEATURES*DATA_WIDTH)-1:0] Wr_flat_reg, Wz_flat_reg, Wh_flat_reg;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] Ur_flat_reg, Uz_flat_reg, Uh_flat_reg;
    always@(*)begin for(i=0;i<W_WORDS;i=i+1)begin Wr_flat_reg[i*32+:32]=Wr_ram[i]; Wz_flat_reg[i*32+:32]=Wz_ram[i]; Wh_flat_reg[i*32+:32]=Wh_ram[i];end for(i=0;i<U_WORDS;i=i+1)begin Ur_flat_reg[i*32+:32]=Ur_ram[i]; Uz_flat_reg[i*32+:32]=Uz_ram[i]; Uh_flat_reg[i*32+:32]=Uh_ram[i];end end
    GRU_Cell #(.DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS), .INPUT_FEATURES(INPUT_FEATURES))
    CELL_INST (.clk(clk), .rstn(rstn), .i_start_cell(cell_start), .o_done_cell(cell_done),
        .i_input_vector_flat(curr_input_vector), .i_prev_hidden_state_flat(curr_hidden),
        .i_Wr_flat(Wr_flat_reg), .i_Ur_flat(Ur_flat_reg), .i_br(br_ram[0]),
        .i_Wz_flat(Wz_flat_reg), .i_Uz_flat(Uz_flat_reg), .i_bz(bz_ram[0]),
        .i_Wh_flat(Wh_flat_reg), .i_Uh_flat(Uh_flat_reg), .i_bh(bh_ram[0]),
        .o_new_hidden_state(cell_new_hidden));

    // --- Main Wrapper FSM ---
    reg [10:0] byte_count, bytes_sent_count; reg [1:0] sub_word_idx; reg [31:0] temp_word;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state<=S_IDLE; byte_count<=0; sub_word_idx<=0; temp_word<=0;
            o_done_seq<=0; proc_state<=P_IDLE; cell_start<=0; tx_start<=0; bytes_sent_count<=0;
        end else begin
            state <= next_state;
            cell_start <= 0;
            tx_start <= 0;
            
            if(state == S_DONE) o_done_seq <= 1; else o_done_seq <= 0;

            if(state == S_RECEIVE && rx_done)begin
                byte_count <= byte_count+1;
                sub_word_idx <= sub_word_idx+1;
                temp_word <= {rx_data, temp_word[31:8]};
                if(sub_word_idx == 3)begin
                    if(byte_count < 48) input_sequence_ram[byte_count/4] <= temp_word;
                    else if(byte_count < 60) Wr_ram[(byte_count-48)/4] <= temp_word;
                    else if(byte_count < 72) Ur_ram[(byte_count-60)/4] <= temp_word;
                    else if(byte_count < 76) br_ram[0] <= temp_word;
                    else if(byte_count < 88) Wz_ram[(byte_count-76)/4] <= temp_word;
                    else if(byte_count < 100) Uz_ram[(byte_count-88)/4] <= temp_word;
                    else if(byte_count < 104) bz_ram[0] <= temp_word;
                    else if(byte_count < 116) Wh_ram[(byte_count-104)/4] <= temp_word;
                    else if(byte_count < 128) Uh_ram[(byte_count-116)/4] <= temp_word;
                    else bh_ram[0] <= temp_word;
                end
            end

            case(proc_state)
                P_IDLE: if(state == S_PROCESS_GRU) begin seq_idx<=0; curr_hidden<=0; proc_state<=P_CELL; end
                P_CELL: begin for(i=0; i<INPUT_FEATURES; i=i+1) begin curr_input_vector[i*32+:32]<=input_sequence_ram[seq_idx*INPUT_FEATURES+i]; end cell_start<=1; proc_state<=P_WAIT; end
                P_WAIT: if(cell_done) begin hidden_sequence_reg[seq_idx*GRU_UNITS*32+:GRU_UNITS*32]<=cell_new_hidden; curr_hidden<=cell_new_hidden; seq_idx<=seq_idx+1; if(seq_idx==SEQ_LENGTH-1) proc_state<=P_DONE; else proc_state<=P_CELL; end
                P_DONE: ;
            endcase

            // **FIX**: The reset logic for bytes_sent_count is now here.
            // It gets reset for one cycle when the processing sub-FSM finishes.
            if(proc_state == P_DONE && cell_done) begin
                bytes_sent_count <= 0;
            end

            if(state == S_SEND_DATA && !tx_busy) begin
                if(bytes_sent_count < HIDDEN_SEQ_BYTES) begin
                    tx_data <= hidden_sequence_reg[bytes_sent_count*8+:8];
                    tx_start <= 1;
                    bytes_sent_count <= bytes_sent_count+1;
                end
            end
        end
    end
    
    always@(*)begin
        next_state=state;
        case(state)
            S_IDLE: next_state=S_RECEIVE;
            S_RECEIVE: if(byte_count==TOTAL_BYTES) next_state=S_PROCESS_GRU;
            S_PROCESS_GRU: if(proc_state==P_DONE && cell_done) begin
                // **FIX**: The conflicting driver has been removed from here.
                next_state=S_SEND_DATA;
            end
            S_SEND_DATA: if(bytes_sent_count==HIDDEN_SEQ_BYTES && !tx_busy) next_state=S_DONE;
            S_DONE: next_state=S_IDLE;
        endcase
    end
endmodule