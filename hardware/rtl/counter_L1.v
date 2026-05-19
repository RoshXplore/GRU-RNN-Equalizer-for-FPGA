`timescale 1ns / 1ps 

module counter_L1 (
	input clk,
	input rstn,
	output reg [31:0] index
);

reg [3:0] counter1;

initial begin
	index = 32'b10000000000000000000000000000000;
	counter1 = 0;
end

always@(posedge clk) begin
	if(!rstn) begin
		index <= 0;
	end else begin
		if(counter1<9) begin
			counter1 <= counter1 + 1'b1;
		end else begin
			index <= index + 1'b1;
			counter1 <= 0;
		end
	end
end

endmodule
		
		
	