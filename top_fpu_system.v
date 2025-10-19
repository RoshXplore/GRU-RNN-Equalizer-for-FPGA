`timescale 1ns / 1ps

module top_fpu_system #(
    parameter DATA_WIDTH = 32
)(
    input clk,
    input rstn,

    // Adder/Multiplier interface
    input [DATA_WIDTH-1:0] a_val,
    input [DATA_WIDTH-1:0] b_val,
    output [DATA_WIDTH-1:0] add_out,
    output [DATA_WIDTH-1:0] mult_out,
    input adder_start,
    input multiplier_start,
    output adder_done,
    output multiplier_done
);

    // --- Adder ---
    adder u_adder (
        .clk(clk),
        .rstn(rstn),
        .start(adder_start),
        .done(adder_done),
        .value_in(a_val),
        .bias(b_val),
        .value_out(add_out)
    );

    // --- Multiplier ---
    multiplier u_mult (
        .clk(clk),
        .rstn(rstn),
        .start(multiplier_start),
        .done(multiplier_done),
        .w(a_val),
        .x(b_val),
        .mult_result(mult_out)
    );

endmodule
