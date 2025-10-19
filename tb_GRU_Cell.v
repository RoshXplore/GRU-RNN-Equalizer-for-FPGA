`timescale 1ns/1ps

module tb_GRU_Cell;

    parameter DATA_WIDTH = 32;
    parameter GRU_UNITS = 3;
    parameter INPUT_FEATURES = 3;
    parameter SEQ_LENGTH = 4;
    localparam CLKS_PER_BIT = 10417;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rstn;
    wire o_done_seq;
    reg dut_rx_wire;
    wire dut_tx_wire;

    // Instantiate the DUT. Ensure GRU_Cell.v and GRU_Cell_wrapper.v are also compiled.
    GRU_Cell_wrapper #( .DATA_WIDTH(DATA_WIDTH), .GRU_UNITS(GRU_UNITS),
        .INPUT_FEATURES(INPUT_FEATURES), .SEQ_LENGTH(SEQ_LENGTH)
    ) DUT ( .clk(clk), .rstn(rstn), .i_uart_rx(dut_rx_wire),
        .o_uart_tx(dut_tx_wire), .o_done_seq(o_done_seq)
    );

    // --- UART Transmitter (to send data to DUT) ---
    reg tx_start; reg [7:0] tx_data; wire tx_busy;
    localparam TX_IDLE=0, TX_START=1, TX_DATA=2, TX_STOP=3; reg [2:0] tx_state;
    reg [13:0] tx_clk_count; reg [3:0] tx_bit_idx; reg [8:0] tx_buf;
    assign tx_busy = (tx_state != TX_IDLE);
    always@(posedge clk or negedge rstn)begin
        if(!rstn)begin tx_state<=TX_IDLE; dut_rx_wire<=1; tx_clk_count<=0;end
        else begin case(tx_state)
            TX_IDLE: begin dut_rx_wire<=1; if(tx_start)begin tx_buf<={tx_data,1'b1}; tx_clk_count<=0; tx_state<=TX_START;end end
            TX_START: begin dut_rx_wire<=0; if(tx_clk_count==CLKS_PER_BIT-1)begin tx_clk_count<=0; tx_bit_idx<=0; tx_state<=TX_DATA;end else tx_clk_count<=tx_clk_count+1;end
            TX_DATA: begin dut_rx_wire<=tx_buf[tx_bit_idx]; if(tx_clk_count==CLKS_PER_BIT-1)begin tx_clk_count<=0; if(tx_bit_idx==7)tx_state<=TX_STOP; else tx_bit_idx<=tx_bit_idx+1;end else tx_clk_count<=tx_clk_count+1;end
            TX_STOP: begin dut_rx_wire<=1; if(tx_clk_count==CLKS_PER_BIT-1)tx_state<=TX_IDLE; else tx_clk_count<=tx_clk_count+1;end
        endcase end
    end

    // --- UART Receiver (to get result from DUT) ---
    reg rx_done; reg [7:0] rx_data;
    localparam RX_IDLE=0, RX_START=1, RX_DATA=2, RX_STOP=3, RX_DONE=4; reg [2:0] rx_state;
    reg [13:0] rx_clk_count; reg [3:0] rx_bit_idx; reg [7:0] rx_data_buf;
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin rx_state<=RX_IDLE; rx_done<=0; rx_clk_count<=0; rx_bit_idx<=0; end
        else begin
            rx_done<=0;
            case(rx_state)
                RX_IDLE: if(!dut_tx_wire) begin rx_clk_count<=0; rx_state<=RX_START; end
                RX_START: if(rx_clk_count==(CLKS_PER_BIT/2)-1) begin rx_clk_count<=0; rx_bit_idx<=0; rx_state<=RX_DATA; end else rx_clk_count<=rx_clk_count+1;
                RX_DATA: if(rx_clk_count==CLKS_PER_BIT-1) begin rx_clk_count<=0; rx_data_buf[rx_bit_idx]<=dut_tx_wire; if(rx_bit_idx==7) rx_state<=RX_STOP; else rx_bit_idx<=rx_bit_idx+1; end else rx_clk_count<=rx_clk_count+1;
                RX_STOP: if(rx_clk_count==CLKS_PER_BIT-1) begin rx_clk_count<=0; rx_state<=RX_DONE; end else rx_clk_count<=rx_clk_count+1;
                RX_DONE: begin rx_data<=rx_data_buf; rx_done<=1; rx_state<=RX_IDLE; end
            endcase
        end
    end

    task send_word(input [31:0] word); begin
        wait(!tx_busy); tx_data<=word[7:0];   tx_start<=1; @(posedge clk); tx_start<=0;
        wait(!tx_busy); tx_data<=word[15:8];  tx_start<=1; @(posedge clk); tx_start<=0;
        wait(!tx_busy); tx_data<=word[23:16]; tx_start<=1; @(posedge clk); tx_start<=0;
        wait(!tx_busy); tx_data<=word[31:24]; tx_start<=1; @(posedge clk); tx_start<=0;
        wait(!tx_busy);
    end endtask

	 
	 // **FIX: All declarations are now at the top of the block**
        reg [(SEQ_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] input_sequence;
        reg [(INPUT_FEATURES*DATA_WIDTH)-1:0] Wr, Wz, Wh;
        reg [(GRU_UNITS*DATA_WIDTH)-1:0] Ur, Uz, Uh;
        reg [DATA_WIDTH-1:0] br, bz, bh;
        reg [(SEQ_LENGTH*GRU_UNITS*DATA_WIDTH)-1:0] final_result;
        integer i;
    initial begin
        

        // Executable code starts AFTER all declarations
        rstn = 0; tx_start = 0; #20; rstn = 1;

        input_sequence = { 32'h41400000, 32'h41300000, 32'h41200000, 32'h41100000, 32'h41000000, 32'h40e00000,
                           32'h40c00000, 32'h40a00000, 32'h40800000, 32'h40400000, 32'h40000000, 32'h3f800000 };
        Wr = 96'h3f800000_40000000_40400000; Ur = 96'h3f800000_40000000_40400000; br = 32'h0;
        Wz = 96'h3f800000_40000000_40400000; Uz = 96'h3f800000_40000000_40400000; bz = 32'h0;
        Wh = 96'h3f800000_40000000_40400000; Uh = 96'h3f800000_40000000_40400000; bh = 32'h0;

        $display("Time: %0t ns - Starting UART data transmission...", $time);
        for (i = 0; i < 12; i = i + 1) send_word(input_sequence[i*32 +: 32]); $display("... input_sequence sent");
        for (i = 0; i < 3; i = i + 1) send_word(Wr[i*32 +: 32]); $display("... Wr sent");
        for (i = 0; i < 3; i = i + 1) send_word(Ur[i*32 +: 32]); $display("... Ur sent");
        send_word(br); $display("... br sent");
        for (i = 0; i < 3; i = i + 1) send_word(Wz[i*32 +: 32]); $display("... Wz sent");
        for (i = 0; i < 3; i = i + 1) send_word(Uz[i*32 +: 32]); $display("... Uz sent");
        send_word(bz); $display("... bz sent");
        for (i = 0; i < 3; i = i + 1) send_word(Wh[i*32 +: 32]); $display("... Wh sent");
        for (i = 0; i < 3; i = i + 1) send_word(Uh[i*32 +: 32]); $display("... Uh sent");
        send_word(bh); $display("... bh sent");

        $display("Time: %0t ns - Data transmission complete. Waiting for DUT...", $time);
        wait(o_done_seq);
        $display("Time: %0t ns - DUT processing complete! Receiving result...", $time);
        
        for (i = 0; i < (SEQ_LENGTH*GRU_UNITS*4); i = i + 1) begin
            wait(rx_done);
            final_result[i*8 +: 8] = rx_data;
        end

        $display("Time: %0t ns - Result reception complete!", $time);
        $display("Hidden Sequence Output: %h", final_result);
        
        #50 $stop;
    end
endmodule