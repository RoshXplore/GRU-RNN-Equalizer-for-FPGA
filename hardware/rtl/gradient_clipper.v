`timescale 1ns / 1ps

module gradient_clipper #(
    parameter DATA_WIDTH = 32
)(
    input wire clk,
    input wire rstn,
    input wire i_start,
    output reg o_done,
    
    input wire [DATA_WIDTH-1:0] i_gradient,
   
    input wire [DATA_WIDTH-1:0] i_clip_threshold, 
    output reg [DATA_WIDTH-1:0] o_clipped_gradient
);

    // Extract Sign and Magnitude
    wire grad_sign = i_gradient[31];
    wire [30:0] grad_mag = i_gradient[30:0];
    wire [30:0] thresh_mag = i_clip_threshold[30:0];

    // Construct the negative threshold 
    wire [31:0] neg_threshold = {1'b1, i_clip_threshold[30:0]};
    wire [31:0] pos_threshold = {1'b0, i_clip_threshold[30:0]};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            o_done <= 0;
            o_clipped_gradient <= 0;
        end else begin
            o_done <= 0;
            
            if (i_start) begin
                
                
                if (grad_mag > thresh_mag) begin
                    // If Magnitude is too large 
                    if (grad_sign) begin
                        o_clipped_gradient <= neg_threshold; // Clamp to -1.0
                    end else begin
                        o_clipped_gradient <= pos_threshold; // Clamp to +1.0
                    end
                end else begin
                    
                    o_clipped_gradient <= i_gradient;
                end
                
                o_done <= 1;
            end
        end
    end

endmodule