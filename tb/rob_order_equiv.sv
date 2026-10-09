module rob_order_equiv(input [4:0] mem_tag, alu_tag, rob_head, output ok);
    wire [4:0] mem_age=mem_tag-rob_head, alu_age=alu_tag-rob_head;
    wire ring_older=(mem_tag<alu_tag) ^ (mem_tag<rob_head) ^ (alu_tag<rob_head);
    assign ok=ring_older==(mem_age<alu_age);
endmodule
