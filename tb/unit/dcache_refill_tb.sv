`timescale 1ns/1ps
module dcache_refill_tb;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, ld_req_valid=0, st_req_valid=0;
    reg [34:0] ld_req_payload=0;
    reg [67:0] st_req_payload=0;
    wire ld_req_ready, ld_rsp_valid, st_req_ready, st_rsp_valid;
    wire [34:0] ld_rsp_payload;
    wire mem_ld_req_valid, mem_st_req_valid;
    wire [38:0] mem_ld_req_payload;
    wire [67:0] mem_st_req_payload;
    reg mem_ld_rsp_valid=0, mem_st_rsp_valid=0;
    reg [38:0] mem_ld_rsp_payload=0;
    integer reads=0, writes=0;
    dcache #(.SIZE_BYTES(512),.WAYS(2),.LINE_BYTES(128),.LQ_DEPTH(2),.GEN_WIDTH(2)) dut (
        .clock,.reset,.ld_req_valid,.ld_req_ready,.ld_req_payload,.ld_rsp_valid,.ld_rsp_payload,
        .st_req_valid,.st_req_ready,.st_req_payload,.st_rsp_valid,
        .mem_ld_req_valid,.mem_ld_req_ready(1'b1),.mem_ld_req_payload,
        .mem_ld_rsp_valid,.mem_ld_rsp_payload,
        .mem_st_req_valid,.mem_st_req_ready(1'b1),.mem_st_req_payload,.mem_st_rsp_valid);
    always @(posedge clock) begin
        mem_ld_rsp_valid<=!reset && mem_ld_req_valid;
        mem_st_rsp_valid<=!reset && mem_st_req_valid;
        if (!reset && mem_ld_req_valid) begin
            if (mem_ld_req_payload[31:7]!=0 ||
                (reads==0 && mem_ld_req_payload[31:0]!=32'h20))
                $fatal(1,"refill must start at the critical word and stay within its line");
            reads<=reads+1;
            mem_ld_rsp_payload<={mem_ld_req_payload[38:32],mem_ld_req_payload[31:0]^32'hc0010000};
        end
        if (!reset && mem_st_req_valid) begin
            writes<=writes+1;
            if (writes<32) begin
                if (mem_st_req_payload[67:36]!=32'(4*writes) || mem_st_req_payload[3:0]!=4'hf ||
                    mem_st_req_payload[35:4]!=(writes==9?32'hc001ab24:(32'(4*writes)^32'hc0010000)))
                    $fatal(1,"dirty writeback lost refill data or byte Store");
            end else if (writes!=32 || mem_st_req_payload!={32'h80000000,32'd13,4'hf})
                $fatal(1,"MMIO must follow the dirty-line writeback");
        end
    end
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task load_word(input [31:0] addr, expected, input id);
        begin
            @(negedge clock); ld_req_valid=1; ld_req_payload={2'd1,id,addr};
            while (!ld_req_ready) @(negedge clock);
            tick; ld_req_valid=0;
            wait(ld_rsp_valid); #1;
            if (ld_rsp_payload!={2'd1,id,expected}) $fatal(1,"Load response data/identity");
            if (reads<32 && (!mem_ld_rsp_valid || ld_rsp_payload[31:0]!=mem_ld_rsp_payload[31:0]))
                $fatal(1,"critical word acquired an extra response cycle");
            tick;
        end
    endtask
    task store_word(input [31:0] addr, value, input [3:0] mask);
        begin
            @(negedge clock); st_req_valid=1; st_req_payload={addr,value,mask};
            while (!st_req_ready) @(negedge clock);
            tick; st_req_valid=0;
            wait(st_rsp_valid); tick;
        end
    endtask
    initial begin
        tick; @(negedge clock); reset=0;
        load_word(32'h20,32'hc0010020,0);
        wait(dut.state==0); #1;
        if (reads!=32) $fatal(1,"refill must transfer exactly one cache line");
        load_word(32'h24,32'hc0010024,1);
        store_word(32'h24,32'h0000ab00,4'b0010);
        load_word(32'h24,32'hc001ab24,0);
        store_word(32'h80000000,13,4'hf);
        if (reads!=32 || writes!=33) $fatal(1,"unexpected memory transaction count");
        $display("PASS dcache_refill: critical response, line wrap, hits, byte Store, dirty/MMIO drain");
        $finish;
    end
    initial begin #10000; $fatal(1,"timeout"); end
endmodule
