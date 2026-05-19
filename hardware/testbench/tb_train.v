`timescale 1ns / 1ps

module tb_train;

    // ========================================================================
    // PARAMETERS
    // ========================================================================
    parameter DATA_WIDTH = 32;
    parameter INPUT_FEATURES = 2;
    parameter GRU_UNITS = 3;
    parameter SEQUENCE_LENGTH = 3;
    parameter OUTPUT_SIZE = 2;
    
    // TRAINING CONFIGURATION
    parameter TOTAL_SAMPLES = 1;  
    parameter NUM_EPOCHS = 50;            
    parameter MEM_FILE = "training_dataset.mem";
    parameter LINES_PER_SAMPLE = 8;
    
    // ========================================================================
    // DUT SIGNALS
    // ========================================================================
    reg clk;
    reg rstn;
    reg i_start_training;
    reg [DATA_WIDTH-1:0] i_learning_rate;

    reg [(SEQUENCE_LENGTH*INPUT_FEATURES*DATA_WIDTH)-1:0] i_input_sequence_flat;
    reg [(OUTPUT_SIZE*DATA_WIDTH)-1:0] i_target_output_flat;

    wire o_training_done;
    wire [DATA_WIDTH-1:0] o_current_loss;
    wire [(OUTPUT_SIZE*DATA_WIDTH)-1:0] o_prediction;
    
    // Weight observation wires
    wire [(INPUT_FEATURES*GRU_UNITS*DATA_WIDTH)-1:0] o_Wr_flat;
    wire [(GRU_UNITS*GRU_UNITS*DATA_WIDTH)-1:0]      o_Ur_flat;
    wire [(GRU_UNITS*DATA_WIDTH)-1:0]                o_br_flat;
    
    // ========================================================================
    // MEMORY FOR DATASET
    // ========================================================================
    reg [31:0] memory_array [0:(TOTAL_SAMPLES*LINES_PER_SAMPLE)-1];
    
    function real hex2real;
        input [31:0] hex;
        begin
            hex2real = $bitstoshortreal(hex);
        end
    endfunction

    // ========================================================================
    // DUT INSTANTIATION (FIXED)
    // ========================================================================
    GRU_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_FEATURES(INPUT_FEATURES),
        .GRU_UNITS(GRU_UNITS),
        .SEQUENCE_LENGTH(SEQUENCE_LENGTH),
        .OUTPUT_SIZE(OUTPUT_SIZE),
		  .BATCH_SIZE(1),
        .CLIP_VAL(32'h3F800000), // Default 1.0 (Debug)
        .SAMPLES_PER_EPOCH(5)    // *** PARAMETER GOES HERE ***
    ) dut (
        // *** PORTS GO HERE ***
        .clk(clk),
        .rstn(rstn),
        .i_start(i_start_training),
        .o_done(o_training_done),
        .i_inference_mode(1'b0),
        .o_prediction(o_prediction),
        .i_input_sequence_flat(i_input_sequence_flat),
        .i_target_output_flat(i_target_output_flat),
        .i_learning_rate(i_learning_rate),
        .o_current_loss(o_current_loss),
		  
        .o_Wr_flat(o_Wr_flat),
        // .SAMPLES_PER_EPOCH(5) <-- REMOVED FROM HERE (This caused the error)
        .o_Ur_flat(o_Ur_flat),
        .o_br_flat(o_br_flat)
    );

    // ========================================================================
    // CLOCK GENERATION
    // ========================================================================
    initial clk = 0;
    always #5 clk = ~clk; // 100MHz

    // ========================================================================
    // MAIN TRAINING SEQUENCE
    // ========================================================================
    integer epoch, s_idx, mem_ptr;
    real current_loss_real;
    real avg_epoch_loss, min_loss, max_loss;
    integer timeout_counter;
    integer loss_file;
    
    initial begin
        // 1. Initialize Signals
        clk = 0;
        rstn = 0;
        i_start_training = 0;
        i_input_sequence_flat = 0;
        i_target_output_flat = 0;
        
        // 0.005 Learning Rate
        i_learning_rate = 32'h3C23D70A; // 0.005 

        // Open log file
        loss_file = $fopen("sgd_loss_log.txt", "w");
        if (loss_file == 0) begin
            $display("[ERROR] Could not open loss log file");
            $finish;
        end
        $fwrite(loss_file, "Epoch,Sample,Loss\n");

        // 2. Load Dataset
        $display("Loading dataset from %s...", MEM_FILE);
        $readmemh(MEM_FILE, memory_array);
        
        // 3. Reset Sequence
        #100;
        rstn = 1;
        #100;

        $display("Starting Training (LR=0.005)...");
        
        // 4. Epoch Loop
        for (epoch = 0; epoch < NUM_EPOCHS; epoch = epoch + 1) begin
            
            avg_epoch_loss = 0.0;
            min_loss = 999999.0;
            max_loss = -999999.0;

            // 5. Sample Loop
            for (s_idx = 0; s_idx < TOTAL_SAMPLES; s_idx = s_idx + 1) begin
                
                // Calculate memory address
                mem_ptr = s_idx * LINES_PER_SAMPLE;
                
                // Load Target
                i_target_output_flat[31:0]  = memory_array[mem_ptr];     
                i_target_output_flat[63:32] = memory_array[mem_ptr + 1]; 
                
                // Load Input Sequence
                i_input_sequence_flat[31:0]    = memory_array[mem_ptr + 2]; 
                i_input_sequence_flat[63:32]   = memory_array[mem_ptr + 3]; 
                i_input_sequence_flat[95:64]   = memory_array[mem_ptr + 4]; 
                i_input_sequence_flat[127:96]  = memory_array[mem_ptr + 5]; 
                i_input_sequence_flat[159:128] = memory_array[mem_ptr + 6]; 
                i_input_sequence_flat[191:160] = memory_array[mem_ptr + 7]; 

                // Start Training Pulse
                @(posedge clk);
                i_start_training = 1;
                @(posedge clk);
                i_start_training = 0;

                // Wait for Done
                timeout_counter = 0;
                while (!o_training_done && timeout_counter < 200000) begin
                    @(posedge clk);
                    timeout_counter = timeout_counter + 1;
                end

                if (timeout_counter >= 200000) begin
                    $display("\n[ERROR] TIMEOUT at Epoch %0d, Sample %0d", epoch, s_idx);
                    $fclose(loss_file);
                    $finish;
                end
                
                // Capture results
                current_loss_real = hex2real(o_current_loss);
                avg_epoch_loss = avg_epoch_loss + current_loss_real;
                
                if (current_loss_real < min_loss) min_loss = current_loss_real;
                if (current_loss_real > max_loss) max_loss = current_loss_real;
                
                $fwrite(loss_file, "%0d,%0d,%f\n", epoch, s_idx, current_loss_real);
                
                repeat(5) @(posedge clk);
            end

            // Epoch Summary
            avg_epoch_loss = avg_epoch_loss / TOTAL_SAMPLES;
            $display("Epoch %2d COMPLETE | Avg: %f", epoch, avg_epoch_loss);
        end

        $fclose(loss_file);
        $display("\nTraining Complete.");
        $finish;
    end
    
    // Global timeout
    initial begin
        #500000000; 
        $display("\n[ERROR] Global simulation timeout!");
        $finish;
    end

endmodule