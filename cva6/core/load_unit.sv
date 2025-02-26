// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba    <zarubaf@iis.ee.ethz.ch>, ETH Zurich
//         Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 15.08.2018
// Description: Load Unit, takes care of all load requests

module load_unit import ariane_pkg::*; #(
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic                     clk_i,    // Clock
    input  logic                     rst_ni,   // Asynchronous reset active low
    input  logic                     flush_i,
    // load unit input port
    input  logic                     valid_i,
    input  lsu_ctrl_t                lsu_ctrl_i,
    output logic                     pop_ld_o,
    // load unit output port
    output logic                     valid_o,
    output logic [TRANS_ID_BITS-1:0] trans_id_o,
    output logic [riscv::VLEN-1:0]   pc_o,      // fot FVT
    output riscv::xlen_t             result_o,
    output exception_t               ex_o,
    // MMU -> Address Translation
    output logic                     translation_req_o,   // request address translation
    output logic [riscv::VLEN-1:0]   vaddr_o,             // virtual address out
    input  logic [riscv::PLEN-1:0]   paddr_i,             // physical address in
    input  exception_t               ex_i,                // exception which may has happened earlier. for example: mis-aligned exception
    input  logic                     dtlb_hit_i,          // hit on the dtlb, send in the same cycle as the request
    input  logic [riscv::PPNW-1:0]   dtlb_ppn_i,          // ppn on the dtlb, send in the same cycle as the request
    // address checker
    output logic [11:0]              page_offset_o,
    input  logic                     page_offset_matches_i,
    input  logic                     store_buffer_empty_i, // the entire store-buffer is empty
    input  logic [TRANS_ID_BITS-1:0] commit_tran_id_i,
    // D$ interface
    //input dcache_req_o_t             req_port_i,
    input dcache_req_o_t             req_port_i_tmp,
    //output dcache_req_i_t            req_port_o,
    output dcache_req_i_t            req_port_o_tmp
);

    //assign req_port_o.data_req  = 1'b0;
    // ============================================================
    //dcache_req_o_t    req_port_i_tmp;
    //dcache_req_i_t    req_port_o_tmp;
    always @(posedge clk_i) begin 
        if (req_port_o_tmp.data_req) begin
            $display("load unit request addr %h size %b", req_port_o_tmp.virtual_address, req_port_o_tmp.data_be);
        end 
    end 

    reg ld_wait_retire;                     // represent a valid load in load_data_q
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            ld_wait_retire <= 0;
        end else begin 
            // a load is waiting to be retired, since the data_gnt is already
            // given and the memory will come back in one cycle  
            // -> rvalid = ld_wait_retire 
            ld_wait_retire <= pop_ld_o;
        end 
    end 
    //assign req_port_i_tmp.data_rvalid = ld_wait_retire;
    //assign req_port_i_tmp.data_rdata = 64'hff00ff0000ff00ff; //64'h1234567812345678;//meme[rd_addr];

    reg [64-1:0] rd_addr;
    always @(posedge clk_i) begin
        if (!rst_ni) rd_addr <= '0;
        else if (req_port_o_tmp.data_req)  /// TODO: gen_block[i].data_req
            rd_addr <= req_port_o_tmp.virtual_address; // pop and proceed to load_data_q stage 
        // rdata = mem[rd_addr] // TODO: gen_block[$past(i)].rvalid / rdata
    end 
    
    //reg arbiter_chosen;
    //always @(posedge clk_i) begin 
    //    if (!rst_ni) arbiter_chosen <= 1;
    //    else arbiter_chosen <= ~arbiter_chosen;
    //end 
    // I.e. i'm selected and the request is sent to memory 
    //assign req_port_i_tmp.data_gnt = arbiter_chosen;// !ld_wait_retire; //TODO: should be arbiter choosen ONLY? (as previous load definitely already processed in the simle sram memory model , so no need to check if previous load in load_data_q is waiting to return
    

    // ============================================================
    
    enum logic [3:0] { IDLE, WAIT_GNT, SEND_TAG, WAIT_PAGE_OFFSET,
                       ABORT_TRANSACTION, ABORT_TRANSACTION_NI, WAIT_TRANSLATION, WAIT_FLUSH,
                       WAIT_WB_EMPTY
                     } state_d, state_q;
    // in order to decouple the response interface from the request interface we need a
    // a queue which can hold all outstanding memory requests
    struct packed {
        logic [TRANS_ID_BITS-1:0] trans_id;
        logic [2:0]               address_offset;
        fu_op                     operator;
        logic [riscv::VLEN-1:0] ld_pc;   // for FVT
    } load_data_d, load_data_q, in_data;

    // page offset is defined as the lower 12 bits, feed through for address checker
    assign page_offset_o = lsu_ctrl_i.vaddr[11:0];
    // feed-through the virtual address for VA translation
    assign vaddr_o = lsu_ctrl_i.vaddr;
    // this is a read-only interface so set the write enable to 0
    assign req_port_o_tmp.data_we = 1'b0;
    assign req_port_o_tmp.data_wdata = '0;
    // compose the queue data, control is handled in the FSM
    assign in_data = {lsu_ctrl_i.trans_id, lsu_ctrl_i.vaddr[2:0], lsu_ctrl_i.operator, lsu_ctrl_i.pc}; // for FVT
    // output address
    // we can now output the lower 12 bit as the index to the cache
    assign req_port_o_tmp.virtual_address = lsu_ctrl_i.vaddr;
    assign req_port_o_tmp.address_index = lsu_ctrl_i.vaddr[ariane_pkg::DCACHE_INDEX_WIDTH-1:0];
    // translation from last cycle, again: control is handled in the FSM
    assign req_port_o_tmp.address_tag   = paddr_i[ariane_pkg::DCACHE_TAG_WIDTH     +
                                              ariane_pkg::DCACHE_INDEX_WIDTH-1 :
                                              ariane_pkg::DCACHE_INDEX_WIDTH];

    assign req_port_o_tmp.pc = lsu_ctrl_i.pc;
    // directly forward exception fields (valid bit is set below)
    assign ex_o.cause = ex_i.cause;
    assign ex_o.tval  = ex_i.tval;

    // Check that NI operations follow the necessary conditions
//    logic paddr_ni;
//    logic not_commit_time;
//    logic inflight_stores;
//    logic stall_ni;
//    assign paddr_ni = is_inside_nonidempotent_regions(ArianeCfg, {dtlb_ppn_i,12'd0});
//    assign not_commit_time = commit_tran_id_i != lsu_ctrl_i.trans_id;
//    assign inflight_stores = (!dcache_wbuffer_not_ni_i || !store_buffer_empty_i);
//    assign stall_ni = (inflight_stores || not_commit_time) && paddr_ni;

    // ---------------
    // Load Control
    // ---------------
    always_comb begin : load_control
        // default assignments
        state_d              = state_q;
        load_data_d          = load_data_q;
        translation_req_o    = 1'b0;
        req_port_o_tmp.data_req  = 1'b0;
        // tag control
        req_port_o_tmp.kill_req  = 1'b0;
        req_port_o_tmp.tag_valid = 1'b0;
        req_port_o_tmp.data_be   = lsu_ctrl_i.be;
        req_port_o_tmp.data_size = extract_transfer_size(lsu_ctrl_i.operator);
        pop_ld_o             = 1'b0;

        case (state_q)
            IDLE: begin
                // we've got a new load request
                if (valid_i) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does then stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        req_port_o_tmp.data_req = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!req_port_i_tmp.data_gnt) begin
                            state_d = WAIT_GNT;
                        end else begin
                            state_d = SEND_TAG;
                            pop_ld_o = 1'b1;
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        state_d = WAIT_PAGE_OFFSET;
                    end
                end
            end

            // wait here for the page offset to not match anymore
            WAIT_PAGE_OFFSET: begin
                // we make a new request as soon as the page offset does not match anymore
                if (!page_offset_matches_i) begin
                    state_d = WAIT_GNT;
                end
            end


            WAIT_GNT: begin
                // keep the translation request up
                translation_req_o = 1'b1;
                // keep the request up
                req_port_o_tmp.data_req = 1'b1;
                // we finally got a data grant
                if (req_port_i_tmp.data_gnt) begin
                    // so we send the tag in the next cycle
                    state_d = SEND_TAG;
                    pop_ld_o = 1'b1;
                end
                // otherwise we keep waiting on our grant
            end
            // we know for sure that the tag we want to send is valid
            SEND_TAG: begin
                req_port_o_tmp.tag_valid = 1'b1;
                state_d = IDLE;
                // we can make a new request here if we got one
                if (valid_i) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        req_port_o_tmp.data_req = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!req_port_i_tmp.data_gnt) begin
                            state_d = WAIT_GNT;
                        end else begin
                            state_d = SEND_TAG;
                            pop_ld_o = 1'b1;
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        state_d = WAIT_PAGE_OFFSET;
                    end
                end
                // ----------
                // Exception
                // ----------
                // if we got an exception we need to kill the request immediately
                if (ex_i.valid) begin
                    req_port_o_tmp.kill_req = 1'b1;
                end
            end

            WAIT_FLUSH: begin
                // the D$ arbiter will take care of presenting this to the memory only in case we
                // have an outstanding request
                req_port_o_tmp.kill_req  = 1'b1;
                req_port_o_tmp.tag_valid = 1'b1;
                // we've killed the current request so we can go back to idle
                state_d = IDLE;
            end
        endcase

        // we got an exception
        if (ex_i.valid && valid_i) begin
            // the next state will be the idle state
            state_d = IDLE;
            // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
            if (!req_port_i_tmp.data_rvalid)
                pop_ld_o = 1'b1;
        end

        // save the load data for later usage -> we should not clutter the load_data register
        if (pop_ld_o && !ex_i.valid) begin
            load_data_d = in_data;
        end

        // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in a extra stage
        if (flush_i) begin
            state_d = WAIT_FLUSH;
        end
    end

    // ---------------
    // Retire Load
    // ---------------
    // decoupled rvalid process
    always_comb begin : rvalid_output
        valid_o    = 1'b0;
        ex_o.valid = 1'b0;
        // output the queue data directly, the valid signal is set corresponding to the process above
        trans_id_o = load_data_q.trans_id;
        pc_o = load_data_q.ld_pc;   // for FVT
        // we got an rvalid and are currently not flushing and not aborting the request
        if (req_port_i_tmp.data_rvalid && state_q != WAIT_FLUSH) begin
            // we killed the request
            if(!req_port_o_tmp.kill_req)
                valid_o = 1'b1;
            // the output is also valid if we got an exception. An exception arrives one cycle after
            // dtlb_hit_i is asserted, i.e. when we are in SEND_TAG. Otherwise, the exception
            // corresponds to the next request that is already being translated (see below).
            if (ex_i.valid && (state_q == SEND_TAG)) begin
                valid_o    = 1'b1;
                ex_o.valid = 1'b1;
            end
        end
        // an exception occurred during translation (we need to check for the valid flag because we could also get an
        // exception from the store unit)
        // exceptions can retire out-of-order -> but we need to give priority to non-excepting load and stores
        // so we simply check if we got an rvalid if so we prioritize it by not retiring the exception - we simply go for another
        // round in the load FSM
        if (valid_i && ex_i.valid && !req_port_i_tmp.data_rvalid) begin
            valid_o    = 1'b1;
            ex_o.valid = 1'b1;
            trans_id_o = lsu_ctrl_i.trans_id;
        // if we are waiting for the translation to finish do not give a valid signal yet
        end 
        //else if (state_q == WAIT_TRANSLATION) begin
        //    valid_o = 1'b0;
        //end
    end


    // latch physical address for the tag cycle (one cycle after applying the index)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q     <= IDLE;
            load_data_q <= '0;
        end else begin
            state_q     <= state_d;
            load_data_q <= load_data_d;
        end
    end

    // ---------------
    // Sign Extend
    // ---------------
    logic [63:0] shifted_data;

    // realign as needed
    assign shifted_data   = req_port_i_tmp.data_rdata >> {load_data_q.address_offset, 3'b000};

/*  // result mux (leaner code, but more logic stages.
    // can be used instead of the code below (in between //result mux fast) if timing is not so critical)
    always_comb begin
        unique case (load_data_q.operator)
            LWU:        result_o = shifted_data[31:0];
            LHU:        result_o = shifted_data[15:0];
            LBU:        result_o = shifted_data[7:0];
            LW:         result_o = 64'(signed'(shifted_data[31:0]));
            LH:         result_o = 64'(signed'(shifted_data[15:0]));
            LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
            default:    result_o = shifted_data;
        endcase
    end  */

    // result mux fast
    logic [7:0]  sign_bits;
    logic [2:0]  idx_d, idx_q;
    logic        sign_bit, signed_d, signed_q, fp_sign_d, fp_sign_q;


    // prepare these signals for faster selection in the next cycle
    assign signed_d  = load_data_d.operator  inside {ariane_pkg::LW,  ariane_pkg::LH,  ariane_pkg::LB};
    assign fp_sign_d = load_data_d.operator  inside {ariane_pkg::FLW, ariane_pkg::FLH, ariane_pkg::FLB};
    assign idx_d     = (load_data_d.operator inside {ariane_pkg::LW,  ariane_pkg::FLW}) ? load_data_d.address_offset + 3 :
                       (load_data_d.operator inside {ariane_pkg::LH,  ariane_pkg::FLH}) ? load_data_d.address_offset + 1 :
                                                                                          load_data_d.address_offset;


    assign sign_bits = { req_port_i_tmp.data_rdata[63],
                         req_port_i_tmp.data_rdata[55],
                         req_port_i_tmp.data_rdata[47],
                         req_port_i_tmp.data_rdata[39],
                         req_port_i_tmp.data_rdata[31],
                         req_port_i_tmp.data_rdata[23],
                         req_port_i_tmp.data_rdata[15],
                         req_port_i_tmp.data_rdata[7]  };

    // select correct sign bit in parallel to result shifter above
    // pull to 0 if unsigned
    assign sign_bit       = signed_q & sign_bits[idx_q] | fp_sign_q;

    // result mux
    always_comb begin
        unique case (load_data_q.operator)
            ariane_pkg::LW, ariane_pkg::LWU, ariane_pkg::FLW:    result_o = {{riscv::XLEN-32{sign_bit}}, shifted_data[31:0]};
            ariane_pkg::LH, ariane_pkg::LHU, ariane_pkg::FLH:    result_o = {{riscv::XLEN-32+16{sign_bit}}, shifted_data[15:0]};
            ariane_pkg::LB, ariane_pkg::LBU, ariane_pkg::FLB:    result_o = {{riscv::XLEN-32+24{sign_bit}}, shifted_data[7:0]};
            default:    result_o = shifted_data[riscv::XLEN-1:0];
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
        if (~rst_ni) begin
            idx_q     <= 0;
            signed_q  <= 0;
            fp_sign_q <= 0;
        end else begin
            idx_q     <= idx_d;
            signed_q  <= signed_d;
            fp_sign_q <= fp_sign_d;
        end
    end
    // end result mux fast

///////////////////////////////////////////////////////
// assertions
///////////////////////////////////////////////////////

//pragma translate_off
`ifndef VERILATOR
    // check invalid offsets
    addr_offset0: assert property (@(posedge clk_i) disable iff (~rst_ni)
        valid_o |->  (load_data_q.operator inside {ariane_pkg::LW, ariane_pkg::LWU}) |-> load_data_q.address_offset < 5) else $fatal (1,"invalid address offset used with {LW, LWU}");
    addr_offset1: assert property (@(posedge clk_i) disable iff (~rst_ni)
        valid_o |->  (load_data_q.operator inside {ariane_pkg::LH, ariane_pkg::LHU}) |-> load_data_q.address_offset < 7) else $fatal (1,"invalid address offset used with {LH, LHU}");
    addr_offset2: assert property (@(posedge clk_i) disable iff (~rst_ni)
        valid_o |->  (load_data_q.operator inside {ariane_pkg::LB, ariane_pkg::LBU}) |-> load_data_q.address_offset < 8) else $fatal (1,"invalid address offset used with {LB, LBU}");
`endif
//pragma translate_on

endmodule
