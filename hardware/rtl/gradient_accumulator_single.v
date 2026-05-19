`timescale 1ns / 1ps

module gradient_accumulator_single #(
    parameter DATA_WIDTH = 32
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_start,
    output reg  o_done,
    
    input  wire [DATA_WIDTH-1:0] i_current_sum,
    input  wire [DATA_WIDTH-1:0] i_new_grad,
    
    output reg [DATA_WIDTH-1:0] o_new_sum
);

    localparam S_IDLE = 0, S_ADD_START = 1, S_ADD_WAIT = 2, S_ADD_ACK = 3, S_DONE = 4;
    reg [2:0] state;
    
    reg add_start;
    wire add_done;
    wire [DATA_WIDTH-1:0] add_res;
    
    adder #(.DATA_WIDTH(DATA_WIDTH)) u_add (
        .clk(clk), .rstn(rstn), .start(add_start), .done(add_done), 
        .value_in(i_current_sum), .bias(i_new_grad), .value_out(add_res)
    );
    
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            state <= S_IDLE; o_done <= 0; o_new_sum <= 0; add_start <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    o_done <= 0; 
                    if(i_start) state <= S_ADD_START;
                end
                
                S_ADD_START: begin
                    add_start <= 1;
                    state <= S_ADD_WAIT;
                end
                
                S_ADD_WAIT: begin
                    if(add_done) begin
                        o_new_sum <= add_res;
                        add_start <= 0; 
                        state <= S_ADD_ACK;
                    end
                end
                
                S_ADD_ACK: begin
                    
                    if(!add_done) state <= S_DONE;
                end
                
                S_DONE: begin
                    o_done <= 1;
                   
                    if(!i_start) begin
                        o_done <= 0;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule