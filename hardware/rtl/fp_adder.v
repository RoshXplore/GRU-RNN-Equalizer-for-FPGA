`timescale 1ns / 1ps 

module fp_adder(
	input clk,
	input rst,
	input [31:0] opa,
	input [31:0] opb,
	input start,
	output reg [31:0] sum,
	output reg ready
);

reg [31:0] s_sum;

reg [3:0] state;

parameter WAIT          = 4'd0,
          UNPACK        = 4'd1,
          SPECIAL_CASES = 4'd2,
          ALIGN         = 4'd3,
          ADD_0         = 4'd4,
          ADD_1         = 4'd5,
          NORMALISE_1   = 4'd6,
          NORMALISE_2   = 4'd7,
          ROUND         = 4'd8,
          PACK          = 4'd9,
          OUT_RDY       = 4'd10;
			 
reg [31:0] opai, opbi, z;
reg [27:0] opa_m, opb_m;
reg [9:0]  opa_e, opb_e, z_e;
reg        opa_s, opb_s, z_s;
reg        guard, round_bit, sticky;
reg [27:0] pre_sum;
reg [23:0] z_m;

always @(negedge rst or posedge clk) begin
	if(!rst) begin
		state <= WAIT;
		ready <= 1'b0;
	end else begin
		case(state)
			WAIT:
          begin
            ready   <= 1'b0;
            if (start) begin
              opai <= opa;
              opbi <= opb;
              state <= UNPACK;
            end
          end
			UNPACK:
          begin
            opa_m    <= {opai[22 : 0], 3'd0};
            opb_m    <= {opbi[22 : 0], 3'd0};
            opa_e    <= opai[30 : 23] - 127;
            opb_e    <= opbi[30 : 23] - 127;
            opa_s    <= opai[31];
            opb_s    <= opbi[31];
            state <= SPECIAL_CASES;
          end
			SPECIAL_CASES:
          begin
            //if a is NaN or b is NaN return NaN 
            if ((opa_e == 128 && opa_m != 0) || (opb_e == 128 && opb_m != 0)) begin
              z[31] <= 1;
              z[30:23] <= 255;
              z[22] <= 1;
              z[21:0] <= 0;
              state <= OUT_RDY;
            //if a is inf return inf
            end else if (opa_e == 128) begin
              z[31] <= opa_s;
              z[30:23] <= 255;
              z[22:0] <= 0;
              //if a is inf and signs don't match return nan
              if ((opb_e == 128) && (opa_s != opb_s)) begin
                  z[31] <= opb_s;
                  z[30:23] <= 255;
                  z[22] <= 1;
                  z[21:0] <= 0;
              end
              state <= OUT_RDY;
            //if b is inf return inf
            end else if (opb_e == 128) begin
              z[31] <= opb_s;
              z[30:23] <= 255;
              z[22:0] <= 0;
              state <= OUT_RDY;
            //if a is zero return b
            end else if ((($signed(opa_e) == -127) && (opa_m == 0)) && (($signed(opb_e) == -127) && (opb_m == 0))) begin
              z[31] <= opa_s & opb_s;
              z[30:23] <= opb_e[7:0] + 127;
              z[22:0] <= opb_m[26:3];
              state <= OUT_RDY;
            //if a is zero return b
            end else if (($signed(opa_e) == -127) && (opa_m == 0)) begin
              z[31] <= opb_s;
              z[30:23] <= opb_e[7:0] + 127;
              z[22:0] <= opb_m[26:3];
              state <= OUT_RDY;
            //if b is zero return a
            end else if (($signed(opb_e) == -127) && (opb_m == 0)) begin
              z[31] <= opa_s;
              z[30:23] <= opa_e[7:0] + 127;
              z[22:0] <= opa_m[26:3];
              state <= OUT_RDY;
            end else begin
              //Denormalised Number
              if ($signed(opa_e) == -127) begin
                opa_e <= -126;
              end else begin
                opa_m[26] <= 1;
              end
              //Denormalised Number
              if ($signed(opb_e) == -127) begin
                opb_e <= -126;
              end else begin
                opb_m[26] <= 1;
              end
              state <= ALIGN;
            end
          end 
			ALIGN:
          begin
            if ($signed(opa_e) > $signed(opb_e)) begin
              opb_e <= opb_e + 1;
              opb_m <= opb_m >> 1;
              opb_m[0] <= opb_m[0] | opb_m[1];
            end else if ($signed(opa_e) < $signed(opb_e)) begin
              opa_e <= opa_e + 1;
              opa_m <= opa_m >> 1;
              opa_m[0] <= opa_m[0] | opa_m[1];
            end else begin
              state <= ADD_0;
            end
          end
			ADD_0:
          begin
            z_e <= opa_e;
            if (opa_s == opb_s) begin
              pre_sum <= opa_m + opb_m;
              z_s <= opa_s;
            end else begin
              if (opa_m >= opb_m) begin
                pre_sum <= opa_m - opb_m;
                z_s <= opa_s;
              end else begin
                pre_sum <= opb_m - opa_m;
                z_s <= opb_s;
              end
            end
            state <= ADD_1;
          end
			ADD_1:
          begin
            if (pre_sum[27]) begin
              z_m <= pre_sum[27:4];
              guard <= pre_sum[3];
              round_bit <= pre_sum[2];
              sticky <= pre_sum[1] | pre_sum[0];
              z_e <= z_e + 1;
            end else begin
              z_m <= pre_sum[26:3];
              guard <= pre_sum[2];
              round_bit <= pre_sum[1];
              sticky <= pre_sum[0];
            end
            state <= NORMALISE_1;
          end
			NORMALISE_1:
          begin
            if (z_m[23] == 0 && $signed(z_e) > -126) begin
              z_e <= z_e - 1;
              z_m <= z_m << 1;
              z_m[0] <= guard;
              guard <= round_bit;
              round_bit <= 0;
            end else begin
              state <= NORMALISE_2;
            end
          end
			NORMALISE_2:
          begin
            if ($signed(z_e) < -126) begin
              z_e <= z_e + 1;
              z_m <= z_m >> 1;
              guard <= z_m[0];
              round_bit <= guard;
              sticky <= sticky | round_bit;
            end else begin
              state <= ROUND;
            end
          end
			ROUND:
          begin
            if (guard && (round_bit | sticky | z_m[0])) begin
              z_m <= z_m + 1;
              if (z_m == 24'hffffff) begin
                z_e <=z_e + 1;
              end
            end
            state <= PACK;
          end
			PACK:
          begin
            z[22 : 0] <= z_m[22:0];
            z[30 : 23] <= z_e[7:0] + 127;
            z[31] <= z_s;
            if ($signed(z_e) == -126 && z_m[23] == 0) begin
              z[30 : 23] <= 0;
            end
            if ($signed(z_e) == -126 && z_m[23:0] == 24'h0) begin
              z[31] <= 1'b0; // FIX SIGN BUG: -a + a = +0.
            end
            //if overflow occurs, return inf
            if ($signed(z_e) > 127) begin
              z[22 : 0] <= 0;
              z[30 : 23] <= 255;
              z[31] <= z_s;
            end
            state <= OUT_RDY;
          end
			OUT_RDY:
          begin
            ready        <= 1'b1;
            sum          <= z;
            state        <= WAIT;
          end
		endcase
	end
end

endmodule
