`timescale 1ns / 1ps

module pre_norm_mul1 (
    input clk_i,
    input [31:0] opa_i,
    input [31:0] opb_i,
    output reg [7:0] exp_10_o,
    output [23:0] fracta_24_o,
    output [23:0] fractb_24_o,
	 output	reg	sign,
	 output reg [1:0] exp_ovf
);

wire		signa, signb;
wire	[7:0]	expa, expb;
wire		expa_dn, expb_dn;
wire		opa_00, opb_00, fracta_00, fractb_00;
wire	[7:0]	exp_out_mul;
wire		co1, co2;
wire	[7:0]	exp_tmp1, exp_tmp2;
wire	[7:0]	exp_tmp3, exp_tmp4, exp_tmp5;
wire	[1:0]	exp_ovf_d;
wire	[7:0]	exp_out_a;
reg sign_d;

//
// Aliases
//
assign  signa = opa_i[31];
assign  signb = opb_i[31];
assign   expa = opa_i[30:23];
assign   expb = opb_i[30:23];


//
// Calculate Exponenet
//

assign expa_dn   = !(|expa);
assign expb_dn   = !(|expb);
assign opa_00    = !(|opa_i[30:0]);
assign opb_00    = !(|opb_i[30:0]);
assign fracta_00 = !(|opa_i[22:0]);
assign fractb_00 = !(|opb_i[22:0]);

assign fracta_24_o = {!expa_dn,opa_i[22:0]};	// Recover hidden bit
assign fractb_24_o = {!expb_dn,opb_i[22:0]};	// Recover hidden bit

assign {co1,exp_tmp1} = (expa + expb);
assign {co2,exp_tmp2} = ({co1,exp_tmp1} - 8'h7f);
assign exp_tmp3 = exp_tmp2 + 1;
assign exp_tmp4 = 8'h7f - exp_tmp1;
assign exp_tmp5 = (exp_tmp4-1);

always@(posedge clk_i)
	exp_10_o <= exp_out_mul;
	
assign exp_out_mul = exp_ovf_d[1] ? exp_out_a : (expa_dn | expb_dn) ? exp_tmp3 : exp_tmp2;
assign exp_out_a   = (expa_dn | expb_dn) ? exp_tmp5 : exp_tmp4;
assign exp_ovf_d[0] = (co2 & expa[7] & expb[7]);
assign exp_ovf_d[1] = ((!expa[7] & !expb[7] & exp_tmp2[7]) | co2);

always @(posedge clk_i)
	exp_ovf <= #1 exp_ovf_d;

//
// Determine sign for the output
//

// sign: 0=Positive Number; 1=Negative Number
always @(signa or signb)
   case({signa, signb})		// synopsys full_case parallel_case
	2'b0_0: sign_d = 0;
	2'b0_1: sign_d = 1;
	2'b1_0: sign_d = 1;
	2'b1_1: sign_d = 0;
   endcase

always @(posedge clk_i)
	sign <= sign_d;
	

endmodule


