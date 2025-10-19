`timescale 1ns / 1ps
module weight_loader #(
    parameter DATA_WIDTH = 32,
    parameter INPUT_FEATURES = 3,
    parameter GRU_UNITS = 3
)(
    input wire clk,
    input wire rstn,
    input wire i_load_weights,
    output reg o_weights_loaded,
    
    // Weight file paths (these will be parameters in actual usage)
    // GRU weights
    output reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] o_Wr_flat,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] o_Ur_flat,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_br_flat,
    output reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] o_Wz_flat,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] o_Uz_flat,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_bz_flat,
    output reg [(GRU_UNITS*INPUT_FEATURES*DATA_WIDTH)-1:0] o_Wh_flat,
    output reg [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0] o_Uh_flat,
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_bh_flat,
    
    // Linear layer weights
    output reg [(GRU_UNITS*DATA_WIDTH)-1:0] o_fc_weights_flat,
    output reg [DATA_WIDTH-1:0] o_fc_bias
);

    // State machine
    localparam S_IDLE = 2'd0,
               S_LOAD = 2'd1,
               S_DONE = 2'd2;
    
    reg [1:0] state;
    
    // Memory to store weights temporarily
    reg [DATA_WIDTH-1:0] Wr_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Ur_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] br_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] Wz_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Uz_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bz_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] Wh_mem [0:GRU_UNITS*INPUT_FEATURES-1];
    reg [DATA_WIDTH-1:0] Uh_mem [0:GRU_UNITS*GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] bh_mem [0:GRU_UNITS-1];
    reg [DATA_WIDTH-1:0] fc_w_mem [0:GRU_UNITS-1];
    
    integer i;
    
    // Task to load weights from files
    task automatic load_weights_from_files;
        begin
            // Load GRU weights for reset gate
            $readmemh("weights/Wr.hex", Wr_mem);
            $readmemh("weights/Ur.hex", Ur_mem);
            $readmemh("weights/br.hex", br_mem);
            
            // Load GRU weights for update gate
            $readmemh("weights/Wz.hex", Wz_mem);
            $readmemh("weights/Uz.hex", Uz_mem);
            $readmemh("weights/bz.hex", bz_mem);
            
            // Load GRU weights for candidate hidden state
            $readmemh("weights/Wh.hex", Wh_mem);
            $readmemh("weights/Uh.hex", Uh_mem);
            $readmemh("weights/bh.hex", bh_mem);
            
            // Load linear layer weights
            $readmemh("weights/fc_weight.hex", fc_w_mem);
            $readmemh("weights/fc_bias.hex", o_fc_bias);
            
            $display("[WEIGHT_LOADER] All weights loaded from files");
        end
    endtask
    
    // Task to flatten weights into output vectors
    task automatic flatten_weights;
        begin
            // Flatten Wr
            for (i = 0; i < GRU_UNITS*INPUT_FEATURES; i = i + 1) begin
                o_Wr_flat[i*DATA_WIDTH +: DATA_WIDTH] = Wr_mem[i];
            end
            
            // Flatten Ur
            for (i = 0; i < GRU_UNITS*GRU_UNITS; i = i + 1) begin
                o_Ur_flat[i*DATA_WIDTH +: DATA_WIDTH] = Ur_mem[i];
            end
            
            // Flatten br
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                o_br_flat[i*DATA_WIDTH +: DATA_WIDTH] = br_mem[i];
            end
            
            // Flatten Wz
            for (i = 0; i < GRU_UNITS*INPUT_FEATURES; i = i + 1) begin
                o_Wz_flat[i*DATA_WIDTH +: DATA_WIDTH] = Wz_mem[i];
            end
            
            // Flatten Uz
            for (i = 0; i < GRU_UNITS*GRU_UNITS; i = i + 1) begin
                o_Uz_flat[i*DATA_WIDTH +: DATA_WIDTH] = Uz_mem[i];
            end
            
            // Flatten bz
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                o_bz_flat[i*DATA_WIDTH +: DATA_WIDTH] = bz_mem[i];
            end
            
            // Flatten Wh
            for (i = 0; i < GRU_UNITS*INPUT_FEATURES; i = i + 1) begin
                o_Wh_flat[i*DATA_WIDTH +: DATA_WIDTH] = Wh_mem[i];
            end
            
            // Flatten Uh
            for (i = 0; i < GRU_UNITS*GRU_UNITS; i = i + 1) begin
                o_Uh_flat[i*DATA_WIDTH +: DATA_WIDTH] = Uh_mem[i];
            end
            
            // Flatten bh
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                o_bh_flat[i*DATA_WIDTH +: DATA_WIDTH] = bh_mem[i];
            end
            
            // Flatten fc weights
            for (i = 0; i < GRU_UNITS; i = i + 1) begin
                o_fc_weights_flat[i*DATA_WIDTH +: DATA_WIDTH] = fc_w_mem[i];
            end
            
            $display("[WEIGHT_LOADER] All weights flattened");
        end
    endtask
    
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            o_weights_loaded <= 0;
            o_Wr_flat <= 0;
            o_Ur_flat <= 0;
            o_br_flat <= 0;
            o_Wz_flat <= 0;
            o_Uz_flat <= 0;
            o_bz_flat <= 0;
            o_Wh_flat <= 0;
            o_Uh_flat <= 0;
            o_bh_flat <= 0;
            o_fc_weights_flat <= 0;
            o_fc_bias <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_weights_loaded <= 0;
                    if (i_load_weights) begin
                        load_weights_from_files();
                        state <= S_LOAD;
                    end
                end
                
                S_LOAD: begin
                    flatten_weights();
                    state <= S_DONE;
                end
                
                S_DONE: begin
                    o_weights_loaded <= 1;
                    if (!i_load_weights) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule