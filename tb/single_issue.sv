module single_issue_test;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0;
    reg [4:0] squash_tag=0;
    reg alu_cand_valid=0, mem_cand_valid=0;
    reg [94:0] alu_cand_uop=0;
    reg [54:0] mem_cand_uop=0;
    reg [63:0] rd_data=0;
    reg [2:0] forward_valid=0;
    reg [17:0] forward_pdst=0;
    reg [95:0] forward_value=0;
    reg alu_exec_ready=1, mul_exec_ready=1, mem_exec_ready=1;
    wire alu_cand_take, mem_cand_take, alu_exec_valid, mul_exec_valid, mem_exec_valid;
    wire early_wake_valid;
    wire [5:0] early_wake_pdst;
    wire [11:0] rd_addr;
    wire [146:0] alu_exec_payload;
    wire [77:0] mul_exec_payload;
    wire [106:0] mem_exec_payload;
    single_issue dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head(5'd30),
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_src2_ready(1'b1), .mem_cand_uop, .mem_cand_take, .rd_addr, .rd_data,
        .forward_valid, .forward_pdst, .forward_value, .early_wake_valid, .early_wake_pdst,
        .alu_exec_valid, .alu_exec_ready, .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready, .mul_exec_payload,
        .mem_exec_valid, .mem_exec_ready, .mem_exec_payload);
    task automatic tick;
        @(posedge clock); #1;
        @(negedge clock);
    endtask
    initial begin
        tick(); reset=0;
        // Wraparound ages: tag 31 is older than tag 1.
        alu_cand_valid=1; mem_cand_valid=1;
        alu_cand_uop={5'd31,2'd0,6'd20,6'd33,6'd32,6'd0,32'h100,32'd0};
        mem_cand_uop={5'd1,3'd7,3'd2,6'd33,6'd32,32'd4};
        rd_data={32'd0,32'd7};
        #1;
        if (!alu_cand_take || mem_cand_take || rd_addr!={6'd0,6'd32})
            $fatal(1,"single issue did not choose oldest ready entry");
        tick(); alu_cand_valid=0;
        if (!alu_exec_valid || !early_wake_valid || early_wake_pdst!=33)
            $fatal(1,"ALU predictive wakeup missing");
        rd_data={32'd7,32'd0};
        tick(); mem_cand_valid=0; mem_exec_ready=0;
        // A dependent store captured stale operands; forward at EX.
        forward_valid=1; forward_pdst[5:0]=33; forward_value[31:0]=32'h12345678;
        #1;
        if (!mem_exec_valid || mem_exec_payload[95:64]!=32'h12345678 ||
            mem_exec_payload[63:32]!=4 || mem_exec_payload[31:0]!=7)
            $fatal(1,"late store operand forwarding failed");
        tick(); forward_valid=0;
        if (mem_exec_payload[95:64]!=32'h12345678)
            $fatal(1,"forwarded value lost during execution backpressure");
        // Keep an older instruction; cancel the younger held store.
        squash_valid=1; squash_tag=31;
        #1;
        if (mem_exec_valid) $fatal(1,"younger memory instruction survived squash");
        tick(); squash_valid=0;
        if (mem_exec_valid) $fatal(1,"cancelled instruction reappeared");
        // The occupied MUL port must not prevent ready ALU work.
        alu_cand_valid=1;
        alu_cand_uop={5'd0,2'd0,6'd38,6'd34,6'd0,6'd0,64'd0};
        tick(); mul_exec_ready=0;
        alu_cand_uop={5'd1,2'd0,6'd11,6'd35,6'd0,6'd0,32'd0,32'd9};
        #1;
        if (!alu_cand_take) $fatal(1,"busy multiplier blocked unrelated ALU");
        tick(); alu_cand_valid=0;
        if (!alu_exec_valid || !mul_exec_valid || mul_exec_payload[72:70]!=0)
            $fatal(1,"single issue resource routing failed");
        $display("PASS single issue forwarding, backpressure, age and cancellation");
        $finish;
    end
endmodule
