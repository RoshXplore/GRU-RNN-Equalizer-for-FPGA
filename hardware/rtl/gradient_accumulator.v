`timescale 1ns / 1ps

module gradient_accumulator #(
    parameter DATA_WIDTH = 32,
    parameter NUM_ELEMENTS = 6
)(
    input  wire clk,
    input  wire rstn,
    input  wire i_clear,              // Clears accumulator (priority signal)
    input  wire i_accumulate,         // Start accumulation pulse
    input  wire [(NUM_ELEMENTS*DATA_WIDTH)-1:0] i_gradient,
    output reg [(NUM_ELEMENTS*DATA_WIDTH)-1:0] o_accumulated,
    output reg o_done_accumulate      // Single-cycle done pulse
);

    // FSM states
    localparam S_IDLE     = 3'd0;
    localparam S_ADD_START = 3'd1;
    localparam S_ADD_WAIT  = 3'd2;
    localparam S_ADD_DROP  = 3'd3;
    localparam S_DONE      = 3'd4;
    
    reg [2:0] state;
    reg [15:0] elem_idx;
    
    // Adder interface
    reg                   add_start;
    wire                  add_done;
    reg  [DATA_WIDTH-1:0] add_a, add_b;
    wire [DATA_WIDTH-1:0] add_result;
    
    adder #(.DATA_WIDTH(DATA_WIDTH)) add_inst (
        .clk(clk), .rstn(rstn),
        .start(add_start), .done(add_done),
        .value_in(add_a), .bias(add_b),
        .value_out(add_result)
    );
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            elem_idx <= 0;
            add_start <= 0;
            o_done_accumulate <= 0;
            o_accumulated <= {(NUM_ELEMENTS*DATA_WIDTH){1'b0}};
        end else begin
            // PRIORITY: Clear overrides all other operations
            if (i_clear) begin
                o_accumulated <= {(NUM_ELEMENTS*DATA_WIDTH){1'b0}};
                o_done_accumulate <= 0;
                state <= S_IDLE;
                elem_idx <= 0;
                add_start <= 0;
            end else begin
                case (state)
                    S_IDLE: begin
                        o_done_accumulate <= 0;
                        add_start <= 0;
                        elem_idx <= 0;
                        
                        if (i_accumulate) begin
                            state <= S_ADD_START;
                        end
                    end
                    
                    S_ADD_START: begin
                        if (elem_idx < NUM_ELEMENTS) begin
                            // Set up addition: current_sum + new_gradient
                            add_a <= o_accumulated[elem_idx*DATA_WIDTH +: DATA_WIDTH];
                            add_b <= i_gradient[elem_idx*DATA_WIDTH +: DATA_WIDTH];
                            add_start <= 1;  // Assert start
                            state <= S_ADD_WAIT;
                        end else begin
                            // All elements processed
                            state <= S_DONE;
                        end
                    end
                    
                    S_ADD_WAIT: begin
                        // Keep start HIGH until done asserts
                        if (add_done) begin
                            // Store result
                            o_accumulated[elem_idx*DATA_WIDTH +: DATA_WIDTH] <= add_result;
                            add_start <= 0;  // Drop start
                            state <= S_ADD_DROP;
                        end
                    end
                    
                    S_ADD_DROP: begin
                        // Wait for done to drop (complete handshake)
                        if (!add_done) begin
                            elem_idx <= elem_idx + 1;
                            state <= S_ADD_START;
                        end
                    end
                    
                    S_DONE: begin
                        o_done_accumulate <= 1;  // Single-cycle pulse
                        state <= S_IDLE;
                    end
                    
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule