`timescale 1ns / 1ps

module GRU_Backward #(
    parameter DATA_WIDTH = 32,
    parameter GRU_UNITS = 3,
    parameter INPUT_FEATURES = 2
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,

    // Inputs
    input wire [(INPUT_FEATURES*DATA_WIDTH)-1:0] i_x_t,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_h_prev,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_r_t,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_z_t,
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_n_t,
    
    // Incoming Gradient
    input wire [(GRU_UNITS*DATA_WIDTH)-1:0]      i_grad_h_t,

    // Weights
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] i_U_hn,
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] i_U_hr,
    input wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] i_U_hz,

    // Outputs
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_ir,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hr,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_r,
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_iz,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hz,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_z,
    output reg [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_grad_W_in,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_grad_U_hn,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_b_n,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0]                o_grad_h_prev
);

    // States
    localparam  S_IDLE              = 5'd0,
                S_GRAD_N            = 5'd1,
                S_GRAD_Z            = 5'd2,
                S_GRAD_H_DIRECT     = 5'd3,
                S_GRAD_A_N          = 5'd4,
                S_GRAD_A_Z          = 5'd5,
                S_GRAD_W_IN         = 5'd6,
                S_GRAD_U_HN         = 5'd7,
                S_GRAD_B_N          = 5'd8,
                S_GRAD_R            = 5'd9,
                S_GRAD_H_CAND       = 5'd10,
                S_GRAD_H_MIX        = 5'd11, 
                S_GRAD_A_R          = 5'd12,
                S_GRAD_W_IR         = 5'd13,
                S_GRAD_U_HR         = 5'd14,
                S_GRAD_B_R          = 5'd15,
                S_GRAD_H_RESET      = 5'd16,
                S_GRAD_W_IZ         = 5'd17,
                S_GRAD_U_HZ         = 5'd18,
                S_GRAD_B_Z          = 5'd19,
                S_GRAD_H_UPDATE     = 5'd20,
                S_COMBINE_H_PREV    = 5'd21,
                S_DONE              = 5'd22;

    reg [4:0] state;

    //  Internal sig
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] grad_n, grad_z;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] grad_a_n, grad_a_z, grad_a_r;
    
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] grad_h_direct, grad_r_base, grad_h_via_n, grad_h_reset, grad_h_update;
    reg [(GRU_UNITS*DATA_WIDTH)-1:0] temp_vector, U_hn_T_grad_an;
    
    reg [7:0] i, j, k;

    reg  mult_start, sub_start, add_start;
    wire mult_done, sub_done, add_done;
    reg [DATA_WIDTH-1:0] mult_a, mult_b, sub_a, sub_b, add_a, add_b;
    wire [DATA_WIDTH-1:0] mult_result, sub_result, add_result;

    multiplier #(DATA_WIDTH) mult_unit (.clk(clk), .rstn(rstn), .start(mult_start), .done(mult_done), .w(mult_a), .x(mult_b), .mult_result(mult_result));
    subtractor #(DATA_WIDTH) sub_unit (.clk(clk), .rstn(rstn), .start(sub_start), .done(sub_done), .value_a(sub_a), .value_b(sub_b), .value_out(sub_result));
    adder #(DATA_WIDTH) add_unit (.clk(clk), .rstn(rstn), .start(add_start), .done(add_done), .value_in(add_a), .bias(add_b), .value_out(add_result));

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; o_done <= 0;
            i <= 0; j <= 0; k <= 0;
            mult_start <= 0; sub_start <= 0; add_start <= 0;
            
            // Reset Outputs
            o_grad_W_ir <= 0; o_grad_U_hr <= 0; o_grad_b_r <= 0;
            o_grad_W_iz <= 0; o_grad_U_hz <= 0; o_grad_b_z <= 0;
            o_grad_W_in <= 0; o_grad_U_hn <= 0; o_grad_b_n <= 0;
            o_grad_h_prev <= 0;
            
            // Reset Internals
            grad_n <= 0; grad_z <= 0; 
            grad_a_n <= 0; grad_a_z <= 0; grad_a_r <= 0;
            grad_h_direct <= 0; grad_r_base <= 0; grad_h_via_n <= 0;
            grad_h_reset <= 0; grad_h_update <= 0;
            temp_vector <= 0; U_hn_T_grad_an <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_done <= 0;
                    if (i_start) begin
                        i <= 0; j <= 0; k <= 0;
                       
                        o_grad_W_ir <= 0; o_grad_U_hr <= 0; o_grad_b_r <= 0;
                        o_grad_W_iz <= 0; o_grad_U_hz <= 0; o_grad_b_z <= 0;
                        o_grad_W_in <= 0; o_grad_U_hn <= 0; o_grad_b_n <= 0;
                        o_grad_h_prev <= 0;
                        
                        grad_n <= 0; grad_z <= 0; 
                        grad_a_n <= 0; grad_a_z <= 0; grad_a_r <= 0;
                        grad_h_direct <= 0; grad_r_base <= 0; grad_h_via_n <= 0;
                        grad_h_reset <= 0; grad_h_update <= 0;
                        temp_vector <= 0; U_hn_T_grad_an <= 0;
                        
                        state <= S_GRAD_N;
                    end
                end

                // 1. grad_n = (1 - z) * grad_h
                S_GRAD_N: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            sub_a <= 32'h3F800000;
                            sub_b <= i_z_t[i*DATA_WIDTH +: DATA_WIDTH];
                            sub_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            sub_start <= 1;
                            if (sub_done) begin
                                sub_start <= 0;
                                mult_a <= sub_result;
                                mult_b <= i_grad_h_t[i*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                grad_n[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_Z;
                    end
                end

                // 2. grad_z
                S_GRAD_Z: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            sub_a <= i_h_prev[i*DATA_WIDTH +: DATA_WIDTH];
                            sub_b <= i_n_t[i*DATA_WIDTH +: DATA_WIDTH];
                            sub_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            sub_start <= 1;
                            if (sub_done) begin
                                sub_start <= 0;
                                mult_a <= sub_result;
                                mult_b <= i_grad_h_t[i*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                grad_z[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_H_DIRECT;
                    end
                end

                // 3. grad_h_direct
                S_GRAD_H_DIRECT: begin
                    if (i < GRU_UNITS) begin
                        mult_a <= i_z_t[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_b <= i_grad_h_t[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_start <= 1;
                        if (mult_done) begin
                            mult_start <= 0;
                            grad_h_direct[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                            i <= i + 1;
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_A_N;
                    end
                end

                // 4. grad_a_n
                S_GRAD_A_N: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            mult_a <= i_n_t[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= i_n_t[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                sub_a <= 32'h3F800000;
                                sub_b <= mult_result;
                                sub_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            sub_start <= 1;
                            if (sub_done) begin
                                sub_start <= 0;
                                mult_a <= grad_n[i*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= sub_result;
                                mult_start <= 1; k <= 3;
                            end
                        end else if (k == 3) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                grad_a_n[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_A_Z;
                    end
                end

                // 5. grad_a_z =
                S_GRAD_A_Z: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            sub_a <= 32'h3F800000;
                            sub_b <= i_z_t[i*DATA_WIDTH +: DATA_WIDTH];
                            sub_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            sub_start <= 1;
                            if (sub_done) begin
                                sub_start <= 0;
                                mult_a <= i_z_t[i*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= sub_result;
                                mult_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0; 
                                mult_b <= mult_result; 
                                k <= 3;
                            end
                        end else if (k == 3) begin
                            
                            mult_a <= grad_z[i*DATA_WIDTH +: DATA_WIDTH];
                            
                            mult_start <= 1; k <= 4;
                        end else if (k == 4) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                grad_a_z[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_W_IN;
                    end
                end

                // 6. grad_W_in
                S_GRAD_W_IN: begin
                    if (i < GRU_UNITS) begin
                        if (j < INPUT_FEATURES) begin
                            mult_a <= i_x_t[j*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= grad_a_n[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                o_grad_W_in[(i*INPUT_FEATURES + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                j <= j + 1;
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; k <= 0; state <= S_GRAD_U_HN;
                    end
                end

                // 7. grad_U_hn 
                S_GRAD_U_HN: begin
                    if (i < GRU_UNITS) begin
                        if (j < GRU_UNITS) begin
                            if (k == 0) begin
                                mult_a <= i_r_t[j*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= i_h_prev[j*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 1;
                            end else if (k == 1) begin
                                mult_start <= 1;
                                if (mult_done) begin
                                    mult_start <= 0; 
                                    mult_a <= mult_result;
                                    mult_b <= grad_a_n[i*DATA_WIDTH +: DATA_WIDTH];
                                    k <= 2; 
                                end
                            end else if (k == 2) begin
                                mult_start <= 1; 
                                k <= 3;
                            end else if (k == 3) begin
                                mult_start <= 1;
                                if (mult_done) begin
                                    mult_start <= 0;
                                    o_grad_U_hn[(i*GRU_UNITS + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                    k <= 0; j <= j + 1;
                                end
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; k <= 0; state <= S_GRAD_B_N;
                    end
                end

                S_GRAD_B_N: begin
                    o_grad_b_n <= grad_a_n;
                    i <= 0; j <= 0; k <= 0; state <= S_GRAD_R;
                end

                // 8. U_hn_T_grad_an
                S_GRAD_R: begin
                    if (i < GRU_UNITS) begin
                        if (j == 0) begin
                            temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= 32'h00000000;
                            j <= j + 1;
                        end else if (j <= GRU_UNITS) begin
                            if (k == 0) begin
                                mult_a <= i_U_hn[((j-1)*GRU_UNITS + i)*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= grad_a_n[(j-1)*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 1;
                            end else if (k == 1) begin
                                mult_start <= 1;
                                if (mult_done) begin
                                    mult_start <= 0;
                                    add_a <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                                    add_b <= mult_result;
                                    add_start <= 1; k <= 2;
                                end
                            end else if (k == 2) begin
                                add_start <= 1;
                                if (add_done) begin
                                    add_start <= 0;
                                    temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                                    k <= 0; j <= j + 1;
                                end
                            end
                        end else begin
                            U_hn_T_grad_an[i*DATA_WIDTH +: DATA_WIDTH] <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_H_CAND;
                    end
                end

                // 9. grad_r_base
                S_GRAD_H_CAND: begin
                    if (i < GRU_UNITS) begin
                        mult_a <= U_hn_T_grad_an[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_b <= i_h_prev[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_start <= 1;
                        if (mult_done) begin
                            mult_start <= 0;
                            grad_r_base[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                            i <= i + 1;
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_H_MIX;
                    end
                end

                // 10. grad_h_via_n
                S_GRAD_H_MIX: begin
                    if (i < GRU_UNITS) begin
                        mult_a <= U_hn_T_grad_an[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_b <= i_r_t[i*DATA_WIDTH +: DATA_WIDTH];
                        mult_start <= 1;
                        if (mult_done) begin
                            mult_start <= 0;
                            grad_h_via_n[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                            i <= i + 1;
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_A_R;
                    end
                end

                // 11. grad_a_r 
                S_GRAD_A_R: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            sub_a <= 32'h3F800000;
                            sub_b <= i_r_t[i*DATA_WIDTH +: DATA_WIDTH];
                            sub_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            sub_start <= 1;
                            if (sub_done) begin
                                sub_start <= 0;
                                mult_a <= i_r_t[i*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= sub_result;
                                mult_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0; 
                                mult_b <= mult_result;
                                k <= 3; 
                            end
                        end else if (k == 3) begin
                           
                            mult_a <= grad_r_base[i*DATA_WIDTH +: DATA_WIDTH];
                            
                            mult_start <= 1; k <= 4;
                        end else if (k == 4) begin
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                grad_a_r[i*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        i <= 0; k <= 0; state <= S_GRAD_W_IR;
                    end
                end

                // 12. grad_W_ir
                S_GRAD_W_IR: begin
                    if (i < GRU_UNITS) begin
                        if (j < INPUT_FEATURES) begin
                            mult_a <= i_x_t[j*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= grad_a_r[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                o_grad_W_ir[(i*INPUT_FEATURES + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                j <= j + 1;
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; state <= S_GRAD_U_HR;
                    end
                end

                // 13. grad_U_hr
                S_GRAD_U_HR: begin
                    if (i < GRU_UNITS) begin
                        if (j < GRU_UNITS) begin
                            mult_a <= i_h_prev[j*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= grad_a_r[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                o_grad_U_hr[(i*GRU_UNITS + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                j <= j + 1;
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; state <= S_GRAD_B_R;
                    end
                end

                S_GRAD_B_R: begin
                    o_grad_b_r <= grad_a_r;
                    i <= 0; j <= 0; k <= 0; state <= S_GRAD_H_RESET;
                end

                // 14. grad_h_reset
                S_GRAD_H_RESET: begin
                    if (i < GRU_UNITS) begin
                        if (j == 0) begin
                            temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= 32'h00000000;
                            j <= j + 1;
                        end else if (j <= GRU_UNITS) begin
                            if (k == 0) begin
                                mult_a <= i_U_hr[((j-1)*GRU_UNITS + i)*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= grad_a_r[(j-1)*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 1;
                            end else if (k == 1) begin
                                mult_start <= 1;
                                if (mult_done) begin
                                    mult_start <= 0;
                                    add_a <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                                    add_b <= mult_result;
                                    add_start <= 1; k <= 2;
                                end
                            end else if (k == 2) begin
                                add_start <= 1;
                                if (add_done) begin
                                    add_start <= 0;
                                    temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                                    k <= 0; j <= j + 1;
                                end
                            end
                        end else begin
                            grad_h_reset[i*DATA_WIDTH +: DATA_WIDTH] <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; state <= S_GRAD_W_IZ;
                    end
                end

                // 15. grad_W_iz
                S_GRAD_W_IZ: begin
                    if (i < GRU_UNITS) begin
                        if (j < INPUT_FEATURES) begin
                            mult_a <= i_x_t[j*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= grad_a_z[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                o_grad_W_iz[(i*INPUT_FEATURES + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                j <= j + 1;
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; state <= S_GRAD_U_HZ;
                    end
                end

                // 16. grad_U_hz
                S_GRAD_U_HZ: begin
                    if (i < GRU_UNITS) begin
                        if (j < GRU_UNITS) begin
                            mult_a <= i_h_prev[j*DATA_WIDTH +: DATA_WIDTH];
                            mult_b <= grad_a_z[i*DATA_WIDTH +: DATA_WIDTH];
                            mult_start <= 1;
                            if (mult_done) begin
                                mult_start <= 0;
                                o_grad_U_hz[(i*GRU_UNITS + j)*DATA_WIDTH +: DATA_WIDTH] <= mult_result;
                                j <= j + 1;
                            end
                        end else begin
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; state <= S_GRAD_B_Z;
                    end
                end

                S_GRAD_B_Z: begin
                    o_grad_b_z <= grad_a_z;
                    i <= 0; j <= 0; k <= 0; state <= S_GRAD_H_UPDATE;
                end

                // 17. grad_h_update
                S_GRAD_H_UPDATE: begin
                    if (i < GRU_UNITS) begin
                        if (j == 0) begin
                            temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= 32'h00000000;
                            j <= j + 1;
                        end else if (j <= GRU_UNITS) begin
                            if (k == 0) begin
                                mult_a <= i_U_hz[((j-1)*GRU_UNITS + i)*DATA_WIDTH +: DATA_WIDTH];
                                mult_b <= grad_a_z[(j-1)*DATA_WIDTH +: DATA_WIDTH];
                                mult_start <= 1; k <= 1;
                            end else if (k == 1) begin
                                mult_start <= 1;
                                if (mult_done) begin
                                    mult_start <= 0;
                                    add_a <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                                    add_b <= mult_result;
                                    add_start <= 1; k <= 2;
                                end
                            end else if (k == 2) begin
                                add_start <= 1;
                                if (add_done) begin
                                    add_start <= 0;
                                    temp_vector[i*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                                    k <= 0; j <= j + 1;
                                end
                            end
                        end else begin
                            grad_h_update[i*DATA_WIDTH +: DATA_WIDTH] <= temp_vector[i*DATA_WIDTH +: DATA_WIDTH];
                            j <= 0; i <= i + 1;
                        end
                    end else begin
                        i <= 0; j <= 0; k <= 0; state <= S_COMBINE_H_PREV;
                    end
                end

                // 18. Final Summation
                S_COMBINE_H_PREV: begin
                    if (i < GRU_UNITS) begin
                        if (k == 0) begin
                            add_a <= grad_h_direct[i*DATA_WIDTH +: DATA_WIDTH];
                            add_b <= grad_h_via_n[i*DATA_WIDTH +: DATA_WIDTH];
                            add_start <= 1; k <= 1;
                        end else if (k == 1) begin
                            add_start <= 1;
                            if (add_done) begin
                                add_start <= 0;
                                add_a <= add_result;
                                add_b <= grad_h_reset[i*DATA_WIDTH +: DATA_WIDTH];
                                add_start <= 1; k <= 2;
                            end
                        end else if (k == 2) begin
                            add_start <= 1;
                            if (add_done) begin
                                add_start <= 0;
                                add_a <= add_result;
                                add_b <= grad_h_update[i*DATA_WIDTH +: DATA_WIDTH];
                                add_start <= 1; k <= 3;
                            end
                        end else if (k == 3) begin
                            add_start <= 1;
                            if (add_done) begin
                                add_start <= 0;
                                o_grad_h_prev[i*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                                i <= i + 1; k <= 0;
                            end
                        end
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    o_done <= 1;
                    if (!i_start) state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
//
//    // --- Debug Probe (Same as before) ---
//    reg prev_done;
//    always @(posedge clk) begin
//        if (rstn) begin
//            if (o_done && !prev_done) begin
//                $display("\n[GRU BACKWARD DONE]");
//                $display("   grad_n (Internal) : %h %h %h", 
//                    grad_n[31:0], grad_n[63:32], grad_n[95:64]);
//                $display("   grad_a_n (Tanh Deriv): %h %h %h", 
//                    grad_a_n[31:0], grad_a_n[63:32], grad_a_n[95:64]);
//                $display("   grad_r_base (At Reset): %h %h %h", 
//                    grad_r_base[31:0], grad_r_base[63:32], grad_r_base[95:64]);
//                $display("   o_grad_W_ir (Output) : %h", o_grad_W_ir[31:0]);
//            end
//            prev_done <= o_done;
//        end
//    end

endmodule