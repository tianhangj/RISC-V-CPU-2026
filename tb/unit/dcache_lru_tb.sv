`timescale 1ns/1ps
module dcache_lru_tb;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, ld_req_valid=0, st_req_valid=0;
    reg [34:0] ld_req_payload=0;
    reg [67:0] st_req_payload=0;
    wire ld_req_ready, ld_rsp_valid, st_req_ready, st_rsp_valid;
    wire [34:0] ld_rsp_payload;
    wire mem_ld_req_valid, mem_st_req_valid;
    wire [35:0] mem_ld_req_payload;
    wire [67:0] mem_st_req_payload;
    reg mem_ld_rsp_valid=0, mem_st_rsp_valid=0;
    reg [35:0] mem_ld_rsp_payload=0;
    reg [31:0] memory [0:63];
    reg [31:0] response_data [0:1];
    reg held_hit_seen=0;
    integer responses [0:1];
    integer reads=0, writes=0;
    dcache #(.SIZE_BYTES(64),.WAYS(2),.LINE_BYTES(16),.LQ_DEPTH(2),.GEN_WIDTH(2)) dut (
        .clock,.reset,.ld_req_valid,.ld_req_ready,.ld_req_payload,.ld_rsp_valid,.ld_rsp_payload,
        .st_req_valid,.st_req_ready,.st_req_payload,.st_rsp_valid,
        .mem_ld_req_valid,.mem_ld_req_ready(1'b1),.mem_ld_req_payload,
        .mem_ld_rsp_valid,.mem_ld_rsp_payload,
        .mem_st_req_valid,.mem_st_req_ready(1'b1),.mem_st_req_payload,.mem_st_rsp_valid);
    always @(posedge clock) begin
        mem_ld_rsp_valid<=!reset && mem_ld_req_valid;
        mem_st_rsp_valid<=!reset && mem_st_req_valid;
        if (!reset && mem_ld_req_valid) begin
            reads<=reads+1;
            mem_ld_rsp_payload<={mem_ld_req_payload[35:32],memory[mem_ld_req_payload[7:2]]};
        end
        if (!reset && mem_st_req_valid) begin
            writes<=writes+1;
            for (integer b=0; b<4; b=b+1)
                if (mem_st_req_payload[b])
                    memory[mem_st_req_payload[43:38]][b*8 +: 8]<=mem_st_req_payload[4+b*8 +: 8];
        end
        if (!reset && ld_rsp_valid) begin
            if (ld_rsp_payload[34:33]!=2'd1) $fatal(1,"response generation");
            responses[ld_rsp_payload[32]]<=responses[ld_rsp_payload[32]]+1;
            response_data[ld_rsp_payload[32]]<=ld_rsp_payload[31:0];
        end
        if (!reset && dut.hum_probe && dut.hum_hit && dut.primary_response)
            held_hit_seen<=1;
    end
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task send_load(input [31:0] addr, input id);
        begin
            @(negedge clock); ld_req_valid=1; ld_req_payload={2'd1,id,addr};
            while (!ld_req_ready) @(negedge clock);
            tick; ld_req_valid=0;
        end
    endtask
    task load_word(input [31:0] addr, expected, input integer expected_reads);
        integer previous;
        begin
            previous=responses[0];
            send_load(addr,0);
            wait(responses[0]>previous); #1;
            if (response_data[0]!=expected) $fatal(1,"load data");
            wait(dut.state==0); #1;
            if (reads!=expected_reads) $fatal(1,"LRU replaced the recently used way");
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
    integer previous0, previous1;
    initial begin
        responses[0]=0; responses[1]=0;
        for (integer w=0; w<64; w=w+1) memory[w]=32'hc0010000 ^ 32'(4*w);
        tick; @(negedge clock); reset=0;
        load_word(32'h00,32'hc0010000,4);
        load_word(32'h20,32'hc0010020,8);
        load_word(32'h00,32'hc0010000,8);
        load_word(32'h40,32'hc0010040,12);
        load_word(32'h00,32'hc0010000,12);
        // A Store hit must also protect its way from replacement.
        store_word(32'h40,32'h0000ab00,4'b0010);
        load_word(32'h20,32'hc0010020,16);
        if (writes!=0) $fatal(1,"recent dirty Store was evicted");
        load_word(32'h40,32'hc001ab40,16);
        load_word(32'h00,32'hc0010000,20);
        load_word(32'h40,32'hc001ab40,20);
        // Probe set 0 during a refill of set 1. Its hit collides with the
        // critical response, so the held hit must still refresh recency.
        previous0=responses[0]; previous1=responses[1];
        send_load(32'h10,0);
        wait(dut.state==4);
        send_load(32'h00,1);
        wait(responses[0]>previous0 && responses[1]>previous1); #1;
        if (response_data[0]!=32'hc0010010 || response_data[1]!=32'hc0010000)
            $fatal(1,"hit-under-miss data/identity");
        wait(dut.state==0); #1;
        if (reads!=24) $fatal(1,"hit-under-miss refilled a resident line");
        if (!held_hit_seen) $fatal(1,"held hit-under-miss was not exercised");
        load_word(32'h60,32'hc0010060,28);
        if (writes!=4) $fatal(1,"hit-under-miss did not update LRU");
        load_word(32'h00,32'hc0010000,28);
        load_word(32'h40,32'hc001ab40,32);
        $display("PASS dcache_lru: Load/Store recency, held hit-under-miss, dirty eviction/refill");
        $finish;
    end
    initial begin #20000; $fatal(1,"timeout"); end
endmodule
