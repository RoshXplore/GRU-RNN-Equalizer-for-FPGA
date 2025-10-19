`timescale 1ns / 1ps 

module mul(clk_i, fracta_i, fractb_i, fract_o);
input		clk_i;
input	[23:0]	fracta_i, fractb_i;
output	[47:0]	fract_o;

reg	[47:0]	prod1, fract_o;

always @(posedge clk_i)
	prod1 <= fracta_i * fractb_i;

always @(posedge clk_i)
	fract_o <= prod1;

endmodule
