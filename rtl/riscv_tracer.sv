// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Andreas Traber - atraber@iis.ee.ethz.ch                    //
//                                                                            //
// Additional contributions by:                                               //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                                                                            //
// Design Name:    RISC-V Tracer                                              //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Traces the executed instructions                           //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

`ifndef VERILATOR

import riscv_defines::*;
import riscv_tracer_defines::*;

// Source/Destination register instruction index
`define REG_S1 19:15
`define REG_S2 24:20
`define REG_S3 29:25
`define REG_S4 31:27
`define REG_D  11:07

module riscv_tracer (
  // Clock and Reset
  input  logic        clk,
  input  logic        rst_n,

  input  logic        fetch_enable,
  input  logic [3:0]  core_id,
  input  logic [5:0]  cluster_id,

  input  logic [31:0] pc,
  input  logic [31:0] instr,
  input  logic        compressed,
  input  logic        id_valid,
  input  logic        is_decoding,
  input  logic        pipe_flush,
  input  logic        mret,
  input  logic        uret,
  input  logic        dret,
  input  logic        ecall,
  input  logic        ebreak,

  input  logic [31:0] rs1_value,
  input  logic [31:0] rs2_value,
  input  logic [31:0] rs3_value,

  input  logic [31:0] rs2_value_vec,

  input  logic        rd_is_fp,
  input  logic        rs1_is_fp,
  input  logic        rs2_is_fp,
  input  logic        rs3_is_fp,

  input  logic        ex_valid,
  input  logic [ 5:0] ex_reg_addr,
  input  logic        ex_reg_we,
  input  logic [31:0] ex_reg_wdata,

  input  logic        ex_data_req,
  input  logic        ex_data_gnt,
  input  logic        ex_data_we,
  input  logic [31:0] ex_data_addr,
  input  logic [31:0] ex_data_wdata,

  input  logic        wb_bypass,

  input  logic        wb_valid,
  input  logic [ 5:0] wb_reg_addr,
  input  logic        wb_reg_we,
  input  logic [31:0] wb_reg_wdata,

  input  logic [31:0] imm_u_type,
  input  logic [31:0] imm_uj_type,
  input  logic [31:0] imm_i_type,
  input  logic [11:0] imm_iz_type,
  input  logic [31:0] imm_z_type,
  input  logic [31:0] imm_s_type,
  input  logic [31:0] imm_sb_type,
  input  logic [31:0] imm_s2_type,
  input  logic [31:0] imm_s3_type,
  input  logic [31:0] imm_vs_type,
  input  logic [31:0] imm_vu_type,
  input  logic [31:0] imm_shuffle_type,
  input  logic [ 4:0] imm_clip_type
);

  integer      f;
  string       fn;
  integer      cycles;
  logic [ 5:0] rd, rs1, rs2, rs3, rs4;

  typedef struct {
    logic [ 5:0] addr;
    logic [31:0] value;
  } reg_t;

  typedef struct {
    logic [31:0] addr;
    logic        we;
    logic [ 3:0] be;
    logic [31:0] wdata;
    logic [31:0] rdata;
  } mem_acc_t;

  class instr_trace_t;
    time         simtime;
    integer      cycles;
    logic [31:0] pc;
    logic [31:0] instr;
    string       str;
    reg_t        regs_read[$];
    reg_t        regs_write[$];
    mem_acc_t    mem_access[$];

    function new ();
      str        = "";
      regs_read  = {};
      regs_write = {};
      mem_access = {};
    endfunction

    function string regAddrToStr(input logic [5:0] addr);
      begin
        if (addr >= 32) begin
          addr -= 32;
          if (addr <= 7)
            return $sformatf("ft%d", addr);
          else if (addr >= 8 && addr <= 9)
            return $sformatf("fs%d", addr-8);
          else if (addr >= 10 && addr <= 17)
            return $sformatf("fa%d", addr-10);
          else if (addr >= 18 && addr <= 27)
            return $sformatf("fs%d", addr-16);
          else if (addr >= 28 && addr <= 31)
            return $sformatf("ft%d", addr-20);
          else
            return $sformatf("x%d", addr+32); // never reached
          end
        else begin
          if (addr == 0)
            return $sformatf("zero");
          else if (addr == 1)
            return $sformatf("ra");
          else if (addr == 2)
            return $sformatf("sp");
          else if (addr == 3)
            return $sformatf("gp");
          else if (addr == 4)
            return $sformatf("tp");
          else if (addr >= 5 && addr <= 7)
            return $sformatf("t%0d", addr-5);
          else if (addr >= 8 && addr <= 9)
            return $sformatf("s%0d", addr-8);
          else if (addr >= 10 && addr <= 17)
            return $sformatf("a%0d", addr-10);
          else if (addr >= 18 && addr <= 27)
            return $sformatf("s%0d", addr-16);
          else if (addr >= 28 && addr <= 31)
            return $sformatf("t%0d", addr-25);
        end
      end
    endfunction

    function void printInstrTrace();
      mem_acc_t mem_acc;
      begin
        $fwrite(f, "%t %15d %h %h %-36s", simtime,
                                          cycles,
                                          pc,
                                          instr,
                                          str);

        foreach(regs_write[i]) begin
          if (regs_write[i].addr != 0)
            $fwrite(f, " %-4s=%08x", regAddrToStr(regs_write[i].addr), regs_write[i].value);
        end

        foreach(regs_read[i]) begin
          if (regs_read[i].addr != 0)
            $fwrite(f, " %-4s:%08x", regAddrToStr(regs_read[i].addr), regs_read[i].value);
        end

        if (mem_access.size() > 0) begin
          mem_acc = mem_access.pop_front();

          $fwrite(f, "  PA:%08x", mem_acc.addr);
        end

        $fwrite(f, "\n");
      end
    endfunction

    function void printMnemonic(input string mnemonic);
      begin
        str = mnemonic;
      end
    endfunction // printMnemonic

    function void printRInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, %s/x%0d, %s/x%0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2);
      end
    endfunction // printRInstr

    function void printAddNInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, %s/x%0d, %s/x%0d, 0x%0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2, $unsigned(imm_s3_type[4:0]));
      end
    endfunction // printAddNInstr

    function void printR1Instr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d,%s/x%0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1);
      end
    endfunction // printR1Instr

    function void printR3Instr(input string mnemonic);
      begin
        regs_read.push_back('{rd, rs3_value});
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d,%s/x%0d,%s/x%0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2);
      end
    endfunction // printR3Instr

    function void printF3Instr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_read.push_back('{rs4, rs3_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s f%0d, f%0d, f%0d, f%0d", mnemonic, rd-32, rs1-32, rs2-32, rs4-32);
      end
    endfunction // printF3Instr

    function void printF2Instr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s f%0d, f%0d, f%0d", mnemonic, rd-32, rs1-32, rs2-32);
      end
    endfunction // printF2Instr

    function void printF2IInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s x%0d, f%0d, f%0d", mnemonic, rd, rs1-32, rs2-32);
      end
    endfunction // printF2IInstr

    function void printFInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s f%0d, f%0d", mnemonic, rd-32, rs1-32);
      end
    endfunction // printFInstr

    function void printFIInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s x%0d, f%0d", mnemonic, rd, rs1-32);
      end
    endfunction // printFIInstr

    function void printIFInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s f%0d, x%0d", mnemonic, rd-32, rs1);
      end
    endfunction // printIFInstr

    function void printClipInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, %s/x%0d, %0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, $unsigned(imm_clip_type));
      end
    endfunction // printRInstr

    function void printIInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, %s/x%0d, %0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, $signed(imm_i_type));
      end
    endfunction // printIInstr

    function void printIuInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, %s/x%0d, 0x%0x", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, imm_i_type);
      end
    endfunction // printIuInstr

    function void printUInstr(input string mnemonic);
      begin
        regs_write.push_back('{rd, 'x});
        str = $sformatf("%-4s %s/x%0d, 0x%0h", mnemonic, regAddrToStr(rd), rd, {imm_u_type[31:12], 12'h000});
      end
    endfunction // printUInstr

    function void printUJInstr(input string mnemonic);
      begin
        regs_write.push_back('{rd, 'x});
        str =  $sformatf("%-4s %s/x%0d, %0d", mnemonic, regAddrToStr(rd), rd, $signed(imm_uj_type));
      end
    endfunction // printUJInstr

    function void printSBInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        str =  $sformatf("%-4s %s/x%0d, %s/x%0d, %0d", mnemonic, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2, $signed(imm_sb_type));
      end
    endfunction // printSBInstr

    function void printSBallInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        str =  $sformatf("%-4s %s/x%0d, %0d", mnemonic, regAddrToStr(rs1), rs1, $signed(imm_sb_type));
      end
    endfunction // printSBInstr

    function void printCSRInstr(input string mnemonic);
      logic [11:0] csr;
      begin
        csr = instr[31:20];

        regs_write.push_back('{rd, 'x});

        if (instr[14] == 1'b0) begin
          regs_read.push_back('{rs1, rs1_value});
          str = $sformatf("%-4s %s/x%0d, %s/x%0d, 0x%h", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, csr);
        end else begin
          str = $sformatf("%-4s %s/x%0d, 0x%h, 0x%h", mnemonic, regAddrToStr(rd), rd, imm_z_type, csr);
        end
      end
    endfunction // printCSRInstr

    function void printBit1Instr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str =  $sformatf("%-4s %s/x%0d, %s/x%0d, %0d, %0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, imm_s3_type, imm_s2_type);
      end
    endfunction

    function void printBitRevInstr(input string mnemonic);
      begin
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str =  $sformatf("%-4s %s/x%0d, %s/x%0d, %0d, %0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, imm_s2_type, imm_s3_type);
      end
    endfunction

    function void printBit2Instr(input string mnemonic);
      begin
        regs_read.push_back('{rd, rs3_value});
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});
        str =  $sformatf("%-4s %s/x%0d, %s/x%0d, %0d, %0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, imm_s3_type, imm_s2_type);
      end
    endfunction

    function void printLoadInstr();
      string mnemonic;
      logic [2:0] size;
      begin

        if (instr[6:0] != OPCODE_CUSTOM_0) begin
          // detect reg-reg load and find size
          size = instr[14:12];
          if (instr[14:12] == 3'b111) begin
            size = instr[30:28];
          end
        end else begin
          size = {instr[28],instr[26:25]};
        end


        case (size)
          3'b000: mnemonic = "lb";
          3'b001: mnemonic = "lh";
          3'b010: mnemonic = "lw";
          3'b100: mnemonic = "lbu";
          3'b101: mnemonic = "lhu";
          3'b110,
          3'b011,
          3'b111: begin
            printMnemonic("INVALID");
            return;
          end
        endcase

        regs_write.push_back('{rd, 'x});

        if (instr[14:12] != 3'b111) begin
          // regular load
          if (instr[6:0] != OPCODE_CUSTOM_0) begin
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("%-4s %s/x%0d, %0d(%s)/%0d(x%0d)", mnemonic, regAddrToStr(rd), rd, $signed(imm_i_type), regAddrToStr(rs1), $signed(imm_i_type), rs1);
          end else begin
            regs_read.push_back('{rs1, rs1_value});
            regs_write.push_back('{rs1, 'x});
            str = $sformatf("p.%-4s %s/x%0d, %0d(%s!)/%0d(x%0d!)", mnemonic, regAddrToStr(rd), rd, $signed(imm_i_type), regAddrToStr(rs1), $signed(imm_i_type), rs1);
          end
        end else begin
          // reg-reg load
          if (instr[6:0] != OPCODE_CUSTOM_0) begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("%-4s %s/x%0d, %s(%s)/x%0d(x%0d)", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs2), regAddrToStr(rs1), rs2, rs1);
          end else begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs1, rs1_value});
            regs_write.push_back('{rs1, 'x});
            str = $sformatf("p.%-4s %s/x%0d, %s(%s!)/x%0d(x%0d!)", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs2), regAddrToStr(rs1), rs2, rs1);
          end
        end
      end
    endfunction

    function void printStoreInstr();
      string mnemonic;
      begin

        case (instr[14:12])
          3'b000:  mnemonic = "sb";
          3'b001:  mnemonic = "sh";
          3'b010:  mnemonic = "sw";
          3'b011:
            case (instr[26:25])
              2'b00:  mnemonic = "sb";
              2'b01:  mnemonic = "sh";
              2'b10:  mnemonic = "sw";
              2'b11: begin
                printMnemonic("INVALID");
                return;
              end
            endcase
          default: begin
            printMnemonic("INVALID");
            return;
          end
        endcase

        if (instr[13:12] == 2'b11) begin
          // regular store
          if (instr[6:0] != OPCODE_CUSTOM_1) begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("%-4s %s/x%0d, %0d(%s)/%0d(x%0d)", mnemonic, regAddrToStr(rs2), rs2, $signed(imm_s_type), regAddrToStr(rs1), $signed(imm_s_type), rs1);
          end else begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs1, rs1_value});
            regs_write.push_back('{rs1, 'x});
            str = $sformatf("cv.%-4s %s/x%0d, %0d(%s)/%0d(x%0d!)", mnemonic, regAddrToStr(rs2), rs2, $signed(imm_s_type), regAddrToStr(rs1), rs1, $signed(imm_s_type));
          end
        end else begin
          // reg-reg store
          if (instr[6:0] != OPCODE_CUSTOM_1) begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs3, rs3_value});
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("cv.%-4s %s/x%0d, %s(%s)/x%0d(x%0d)", mnemonic, regAddrToStr(rs2), rs2, regAddrToStr(rs3), regAddrToStr(rs1), rs3, rs1);
          end else begin
            regs_read.push_back('{rs2, rs2_value});
            regs_read.push_back('{rs3, rs3_value});
            regs_read.push_back('{rs1, rs1_value});
            regs_write.push_back('{rs1, 'x});
            str = $sformatf("cv.%-4s %s/x%0d, %s(%s!)/x%0d(x%0d!)", mnemonic, regAddrToStr(rs2), rs2, regAddrToStr(rs3), regAddrToStr(rs1), rs3, rs1);
          end
        end
      end
    endfunction // printSInstr

    function void printHwloopInstr();
      string mnemonic;
      begin
        // set mnemonic
        case (instr[14:12])
          3'b000: mnemonic = "lp.starti";
          3'b001: mnemonic = "lp.endi";
          3'b010: mnemonic = "lp.count";
          3'b011: mnemonic = "lp.counti";
          3'b100: mnemonic = "lp.setup";
          3'b101: mnemonic = "lp.setupi";
          3'b111: begin
            printMnemonic("INVALID");
            return;
          end
        endcase

        // decode and print instruction
        case (instr[14:12])
          // lp.starti and lp.endi
          3'b000,
          3'b001: str = $sformatf("%-4s %s/0x%0d, 0x%0h", mnemonic, regAddrToStr(rd), rd, imm_iz_type);
          // lp.count
          3'b010: begin
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("%-4s %s/0x%0d, %s/x%0d", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1);
          end
          // lp.counti
          3'b011: str = $sformatf("%-4s %s/x%0d, 0x%0h", mnemonic, regAddrToStr(rd), rd, imm_iz_type);
          // lp.setup
          3'b100: begin
            regs_read.push_back('{rs1, rs1_value});
            str = $sformatf("%-4s %s/0x%0d, %s/x%0d, 0x%0h", mnemonic, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, imm_iz_type);
          end
          // lp.setupi
          3'b101: begin
            str = $sformatf("%-4s %s/0x%0d, 0x%0h, %s/x%0d", mnemonic, regAddrToStr(rd), rd, imm_iz_type, regAddrToStr(rs1), rs1);
          end
        endcase
      end
    endfunction

    function void printMulInstr();
      string mnemonic;
      string str_suf;
      string str_imm;
      string str_asm;
      begin

        // always read rs1 and rs2 and write rd
        regs_read.push_back('{rs1, rs1_value});
        regs_read.push_back('{rs2, rs2_value});
        regs_write.push_back('{rd, 'x});

        // 12: u/!s
        // 13: mac/!mul
        // 14: 16b/!32b
        // 30: hh
        // 31: R
        if (instr[13])
          mnemonic = "p.mac";
        else
          mnemonic = "p.mul";

        if (instr[30])
          mnemonic = $sformatf("%shh", mnemonic);

        if (instr[12])
          mnemonic = $sformatf("%su", mnemonic);
        else
          mnemonic = $sformatf("%ss", mnemonic);

        if (instr[31])
          mnemonic = $sformatf("%sR", mnemonic);

        if (imm_s3_type[4:0] != 5'b00000)
          mnemonic = $sformatf("%sN", mnemonic);

        if (instr[29:25] != 5'b00000)
          str = $sformatf("%-4s %s/x%0d, %s/x%0d, %s/x%0d, %0d", str_asm, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2, $unsigned(imm_s3_type[4:0]));
        else
          str = $sformatf("%-4s %s/x%0d, %s/x%0d, %s/x%0d", str_asm, regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2);
      end
    endfunction

    function void printVecInstr();
      string mnemonic;
      string str_asm;
      string str_args;
      string str_hb;
      string str_sci;
      string str_imm;
      begin

        // always read rs1 and write rd
        regs_read.push_back('{rs1, rs1_value});
        regs_write.push_back('{rd, 'x});

        case (instr[14:13])
          2'b00: str_sci = "";
          2'b10: str_sci = ".sc";
          2'b11: str_sci = ".sci";
        endcase

        if (instr[12])
          str_hb = ".b";
        else
          str_hb = ".h";

        // set mnemonic
        case (instr[31:26])
          6'b000000: begin mnemonic = "cv.add";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000010: begin mnemonic = "cv.sub";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000100: begin mnemonic = "cv.avg";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000110: begin mnemonic = "cv.avgu";     str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b001000: begin mnemonic = "cv.min";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b001010: begin mnemonic = "cv.minu";     str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b001100: begin mnemonic = "cv.max";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b001110: begin mnemonic = "cv.maxu";     str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b010000: begin mnemonic = "cv.srl";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b010010: begin mnemonic = "cv.sra";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b010100: begin mnemonic = "cv.sll";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b010110: begin mnemonic = "cv.or";       str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b011000: begin mnemonic = "cv.xor";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b011010: begin mnemonic = "cv.and";      str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b011100: begin mnemonic = "cv.abs";      str_imm = $sformatf("0x%0d", imm_vs_type); end

          6'b011110: begin mnemonic = "cv.extract";  str_imm = $sformatf("0x%0d", imm_vs_type); str_sci = ""; end
          6'b100100: begin mnemonic = "cv.extractu"; str_imm = $sformatf("0x%0d", imm_vu_type); str_sci = ""; end
          6'b101100: begin mnemonic = "cv.insert";   str_imm = $sformatf("0x%0d", imm_vs_type); end

          // shuffle/pack
          6'b110000: begin mnemonic = "cv.shuffle";   end
          6'b110000: begin mnemonic = "cv.shufflei0"; str_imm = $sformatf("0x%0d", imm_shuffle_type);  end
          6'b111010: begin mnemonic = "cv.shufflei1"; str_imm = $sformatf("0x%0d", imm_shuffle_type);  end
          6'b111100: begin mnemonic = "cv.shufflei2"; str_imm = $sformatf("0x%0d", imm_shuffle_type);  end
          6'b111110: begin mnemonic = "cv.shufflei3"; str_imm = $sformatf("0x%0d", imm_shuffle_type);  end

          6'b110010: begin mnemonic = "cv.shuffle2"; end

          6'b110100: begin mnemonic = instr[25] ? "cv.pack.h" : "cv.pack"; end
          6'b110110: begin mnemonic = "cv.packhi";                         end
          6'b111000: begin mnemonic = "cv.packlo";                         end

          // comparisons
          6'b000001: begin mnemonic = "cv.cmpeq";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000011: begin mnemonic = "cv.cmpne";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000101: begin mnemonic = "cv.cmpgt";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b000111: begin mnemonic = "cv.cmpge";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b001001: begin mnemonic = "cv.cmplt";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b001011: begin mnemonic = "cv.cmple";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b001101: begin mnemonic = "cv.cmpgtu";   str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b001111: begin mnemonic = "cv.cmpgeu";   str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b010001: begin mnemonic = "cv.cmpltu";   str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b010011: begin mnemonic = "cv.cmpleu";   str_imm = $sformatf("0x%0d", imm_vu_type); end

          // dotproducts
          6'b100000: begin mnemonic = "cv.dotup";    str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b100010: begin mnemonic = "cv.dotusp";   str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b100110: begin mnemonic = "cv.dotsp";    str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b101000: begin mnemonic = "cv.sdotup";   str_imm = $sformatf("0x%0d", imm_vu_type); end
          6'b101010: begin mnemonic = "cv.sdotusp";  str_imm = $sformatf("0x%0d", imm_vs_type); end
          6'b101110: begin mnemonic = "cv.sdotsp";   str_imm = $sformatf("0x%0d", imm_vs_type); end

          6'b010101: begin
            unique case (instr[14:13])
               2'b00: mnemonic = instr[25] ? "cv.clpxmul.r"      : "cv.clpxmul.i";
               2'b01: mnemonic = instr[25] ? "cv.clpxmul.r.div2" : "cv.clpxmul.i.div2";
               2'b10: mnemonic = instr[25] ? "cv.clpxmul.r.div4" : "cv.clpxmul.i.div4";
               2'b11: mnemonic = instr[25] ? "cv.clpxmul.r.div8" : "cv.clpxmul.i.div8";
            endcase
            str_sci = "";
          end

          6'b011011: begin
            unique case (instr[14:13])
               2'b00: mnemonic = "cv.subrotmj";
               2'b01: mnemonic = "cv.subrotmj.div2";
               2'b10: mnemonic = "cv.subrotmj.div4";
               2'b11: mnemonic = "cv.subrotmj.div8";
            endcase
            str_sci = "";
          end

          6'b010111: begin mnemonic = "cv.cplxconj";  end

          6'b011101: begin
            unique case (instr[14:13])
               2'b01: mnemonic = "cv.add.div2";
               2'b10: mnemonic = "cv.add.div4";
               2'b11: mnemonic = "cv.add.div8";
            endcase
            str_sci = "";
          end

          6'b011001: begin
            unique case (instr[14:13])
               2'b01: mnemonic = "cv.sub.div2";
               2'b10: mnemonic = "cv.sub.div4";
               2'b11: mnemonic = "cv.sub.div8";
            endcase
            str_sci = "";
          end

          default: begin
            printMnemonic("INVALID");
            return;
          end
        endcase

        if (str_sci == "") begin
          regs_read.push_back('{rs2, rs2_value});
          str_args = $sformatf("%s/x%0d, %s/x%0d, %s/x%0d", regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2);
        end else if (str_sci == ".sc") begin
          regs_read.push_back('{rs2, rs2_value_vec});
          str_args = $sformatf("%s/x%0d, %s/x%0d, %s/x%0d", regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, regAddrToStr(rs2), rs2);
        end else if (str_sci == ".sci") begin
          str_args = $sformatf("%s/x%0d, %s/x%0d, %s", regAddrToStr(rd), rd, regAddrToStr(rs1), rs1, str_imm);
        end

        str_asm = $sformatf("%s%s%s", mnemonic, str_sci, str_hb);

        str = $sformatf("%-4s %s", str_asm, str_args);
      end
    endfunction
  endclass

  mailbox #(instr_trace_t) instr_ex = new ();
  mailbox #(instr_trace_t) instr_wb = new ();

  // cycle counter
  always_ff @(posedge clk, negedge rst_n)
  begin
    if (rst_n == 1'b0)
      cycles = 0;
    else
      cycles = cycles + 1;
  end

  // open/close output file for writing
  initial
  begin
    wait(rst_n == 1'b1);
    $sformat(fn, "trace_core_%h_%h.log", cluster_id, core_id);
    // $display("[TRACER] Output filename is: %s", fn);
    f = $fopen(fn, "w");
    $fwrite(f, "                Time          Cycles PC       Instr    Mnemonic\n");

  end

  final
  begin
    $fclose(f);
  end

  assign rd  = {rd_is_fp,  instr[`REG_D]};
  assign rs1 = {rs1_is_fp, instr[`REG_S1]};
  assign rs2 = {rs2_is_fp, instr[`REG_S2]};
  assign rs3 = {rs3_is_fp, instr[`REG_S3]};
  assign rs4 = {rs3_is_fp, instr[`REG_S4]};

  // virtual ID/EX pipeline
  initial
  begin
    instr_trace_t trace;
    mem_acc_t     mem_acc;

    while(1) begin
      instr_ex.get(trace);

      // wait until we are going to the next stage
      do begin
        @(negedge clk);

        // replace register written back
        foreach(trace.regs_write[i])
          if ((trace.regs_write[i].addr == ex_reg_addr) && ex_reg_we)
            trace.regs_write[i].value = ex_reg_wdata;

        // look for data accesses and log them
        if (ex_data_req && ex_data_gnt) begin
          mem_acc.addr = ex_data_addr;
          mem_acc.we   = ex_data_we;

          if (mem_acc.we)
            mem_acc.wdata = ex_data_wdata;
          else
            mem_acc.wdata = 'x;

          trace.mem_access.push_back(mem_acc);
        end
      end while (!ex_valid && !wb_bypass); // ex branches bypass the WB stage

      instr_wb.put(trace);
    end
  end

  // virtual EX/WB pipeline
  initial
  begin
    instr_trace_t trace;

    while(1) begin
      instr_wb.get(trace);

      // wait until we are going to the next stage
      do begin
        @(negedge clk);

        // replace register written back
        foreach(trace.regs_write[i])
          if ((trace.regs_write[i].addr == wb_reg_addr) && wb_reg_we)
            trace.regs_write[i].value = wb_reg_wdata;
      end while (!wb_valid);

      trace.printInstrTrace();
    end
  end


  // these signals are for simulator visibility. Don't try to do the nicer way
  // of making instr_trace_t visible to inspect it with your simulator. Some
  // choke for some unknown performance reasons.
  string insn_disas;
  logic [31:0] insn_pc;
  logic [31:0] insn_val;

  // log execution
  always @(negedge clk)
  begin
    instr_trace_t trace;

    // special case for WFI because we don't wait for unstalling there
    if ( (id_valid || pipe_flush || mret || uret || ecall || ebreak || dret) && is_decoding)
    begin
      trace = new ();

      trace.simtime    = $time;
      trace.cycles     = cycles;
      trace.pc         = pc;
      trace.instr      = instr;

      // use casex instead of case inside due to ModelSim bug
      casex (instr)
        // Aliases
        32'h00_00_00_13:   trace.printMnemonic("nop");
        // Regular opcodes
        INSTR_LUI:        trace.printUInstr("lui");
        INSTR_AUIPC:      trace.printUInstr("auipc");
        INSTR_JAL:        trace.printUJInstr("jal");
        INSTR_JALR:       trace.printIInstr("jalr");
        // BRANCH
        INSTR_BEQ:        trace.printSBInstr("beq");
        INSTR_BNE:        trace.printSBInstr("bne");
        INSTR_BLT:        trace.printSBInstr("blt");
        INSTR_BGE:        trace.printSBInstr("bge");
        INSTR_BLTU:       trace.printSBInstr("bltu");
        INSTR_BGEU:       trace.printSBInstr("bgeu");
        INSTR_BEQIMM:     trace.printSBallInstr("p.beqimm");
        INSTR_BNEIMM:     trace.printSBallInstr("p.bneimm");
        // OPIMM
        INSTR_ADDI:       trace.printIInstr("addi");
        INSTR_SLTI:       trace.printIInstr("slti");
        INSTR_SLTIU:      trace.printIInstr("sltiu");
        INSTR_XORI:       trace.printIInstr("xori");
        INSTR_ORI:        trace.printIInstr("ori");
        INSTR_ANDI:       trace.printIInstr("andi");
        INSTR_SLLI:       trace.printIuInstr("slli");
        INSTR_SRLI:       trace.printIuInstr("srli");
        INSTR_SRAI:       trace.printIuInstr("srai");
        // OP
        INSTR_ADD:        trace.printRInstr("add");
        INSTR_SUB:        trace.printRInstr("sub");
        INSTR_SLL:        trace.printRInstr("sll");
        INSTR_SLT:        trace.printRInstr("slt");
        INSTR_SLTU:       trace.printRInstr("sltu");
        INSTR_XOR:        trace.printRInstr("xor");
        INSTR_SRL:        trace.printRInstr("srl");
        INSTR_SRA:        trace.printRInstr("sra");
        INSTR_OR:         trace.printRInstr("or");
        INSTR_AND:        trace.printRInstr("and");
        INSTR_EXTHS:      trace.printRInstr("cv.exths");
        INSTR_EXTHZ:      trace.printRInstr("cv.exthz");
        INSTR_EXTBS:      trace.printRInstr("cv.extbs");
        INSTR_EXTBZ:      trace.printRInstr("cv.extbz");
        INSTR_PAVG:       trace.printRInstr("cv.avg");
        INSTR_PAVGU:      trace.printRInstr("cv.avgu");

        INSTR_PADDN:      trace.printAddNInstr("cv.addN");
        INSTR_PADDUN:     trace.printAddNInstr("cv.adduN");
        INSTR_PADDRN:     trace.printAddNInstr("cv.addRN");
        INSTR_PADDURN:    trace.printAddNInstr("cv.adduRN");
        INSTR_PSUBN:      trace.printAddNInstr("cv.subN");
        INSTR_PSUBUN:     trace.printAddNInstr("cv.subuN");
        INSTR_PSUBRN:     trace.printAddNInstr("cv.subRN");
        INSTR_PSUBURN:    trace.printAddNInstr("cv.subuRN");

        INSTR_PADDNR:     trace.printR3Instr("cv.addNr");
        INSTR_PADDUNR:    trace.printR3Instr("cv.adduNr");
        INSTR_PADDRNR:    trace.printR3Instr("cv.addRNr");
        INSTR_PADDURNR:   trace.printR3Instr("cv.adduRNr");
        INSTR_PSUBNR:     trace.printR3Instr("cv.subNr");
        INSTR_PSUBUNR:    trace.printR3Instr("cv.subuNr");
        INSTR_PSUBRNR:    trace.printR3Instr("cv.subRNr");
        INSTR_PSUBURNR:   trace.printR3Instr("cv.subuRNr");

        INSTR_PSLET:      trace.printRInstr("cv.slet");
        INSTR_PSLETU:     trace.printRInstr("cv.sletu");
        INSTR_PMIN:       trace.printRInstr("cv.min");
        INSTR_PMINU:      trace.printRInstr("cv.minu");
        INSTR_PMAX:       trace.printRInstr("cv.max");
        INSTR_PMAXU:      trace.printRInstr("cv.maxu");
        INSTR_PABS:       trace.printR1Instr("cv.abs");
        INSTR_PCLIP:      trace.printClipInstr("cv.clip");
        INSTR_PCLIPU:     trace.printClipInstr("cv.clipu");
        INSTR_PBEXT:      trace.printBit1Instr("cv.extract");
        INSTR_PBEXTU:     trace.printBit1Instr("cv.extractu");
        INSTR_PBINS:      trace.printBit2Instr("cv.insert");
        INSTR_PBCLR:      trace.printBit1Instr("cv.bclr");
        INSTR_PBSET:      trace.printBit1Instr("cv.bset");
        INSTR_PBREV:      trace.printBitRevInstr("cv.bitrev");

        INSTR_PCLIPR:     trace.printRInstr("cv.clipr");
        INSTR_PCLIPUR:    trace.printRInstr("cv.clipur");
        INSTR_PBEXTR:     trace.printRInstr("cv.extractr");
        INSTR_PBEXTUR:    trace.printRInstr("cv.extractur");
        INSTR_PBINSR:     trace.printR3Instr("cv.insertr");
        INSTR_PBCLRR:     trace.printRInstr("cv.bclrr");
        INSTR_PBSETR:     trace.printRInstr("cv.bsetr");


        INSTR_FF1:        trace.printR1Instr("cv.ff1");
        INSTR_FL1:        trace.printR1Instr("cv.fl1");
        INSTR_CLB:        trace.printR1Instr("cv.clb");
        INSTR_CNT:        trace.printR1Instr("cv.cnt");
        INSTR_ROR:        trace.printRInstr("cv.ror");

        // FENCE
        INSTR_FENCE:      trace.printMnemonic("fence");
        INSTR_FENCEI:     trace.printMnemonic("fencei");
        // SYSTEM (CSR manipulation)
        INSTR_CSRRW:      trace.printCSRInstr("csrrw");
        INSTR_CSRRS:      trace.printCSRInstr("csrrs");
        INSTR_CSRRC:      trace.printCSRInstr("csrrc");
        INSTR_CSRRWI:     trace.printCSRInstr("csrrwi");
        INSTR_CSRRSI:     trace.printCSRInstr("csrrsi");
        INSTR_CSRRCI:     trace.printCSRInstr("csrrci");
        // SYSTEM (others)
        INSTR_ECALL:      trace.printMnemonic("ecall");
        INSTR_EBREAK:     trace.printMnemonic("ebreak");
        INSTR_URET:       trace.printMnemonic("uret");
        INSTR_MRET:       trace.printMnemonic("mret");
        INSTR_WFI:        trace.printMnemonic("wfi");

        INSTR_DRET:       trace.printMnemonic("dret");

        // RV32M
        INSTR_PMUL:       trace.printRInstr("mul");
        INSTR_PMUH:       trace.printRInstr("mulh");
        INSTR_PMULHSU:    trace.printRInstr("mulhsu");
        INSTR_PMULHU:     trace.printRInstr("mulhu");
        INSTR_DIV:        trace.printRInstr("div");
        INSTR_DIVU:       trace.printRInstr("divu");
        INSTR_REM:        trace.printRInstr("rem");
        INSTR_REMU:       trace.printRInstr("remu");
        // PULP MULTIPLIER
        INSTR_PMAC:       trace.printR3Instr("cv.mac");
        INSTR_PMSU:       trace.printR3Instr("cv.msu");
        INSTR_PMULSN:     trace.printMulInstr();
        INSTR_PMULHHSN:   trace.printMulInstr();
        INSTR_PMULSRN:    trace.printMulInstr();
        INSTR_PMULHHSRN:  trace.printMulInstr();
        INSTR_PMULUN:     trace.printMulInstr();
        INSTR_PMULHHUN:   trace.printMulInstr();
        INSTR_PMULURN:    trace.printMulInstr();
        INSTR_PMULHHURN:  trace.printMulInstr();
        INSTR_PMACSN:     trace.printMulInstr();
        INSTR_PMACHHSN:   trace.printMulInstr();
        INSTR_PMACSRN:    trace.printMulInstr();
        INSTR_PMACHHSRN:  trace.printMulInstr();
        INSTR_PMACUN:     trace.printMulInstr();
        INSTR_PMACHHUN:   trace.printMulInstr();
        INSTR_PMACURN:    trace.printMulInstr();
        INSTR_PMACHHURN:  trace.printMulInstr();

        // FP-OP
        INSTR_FMADD:      trace.printF3Instr("fmadd.s");
        INSTR_FMSUB:      trace.printF3Instr("fmsub.s");
        INSTR_FNMADD:     trace.printF3Instr("fnmadd.s");
        INSTR_FNMSUB:     trace.printF3Instr("fnmsub.s");
        INSTR_FADD:       trace.printF2Instr("fadd.s");
        INSTR_FSUB:       trace.printF2Instr("fsub.s");
        INSTR_FMUL:       trace.printF2Instr("fmul.s");
        INSTR_FDIV:       trace.printF2Instr("fdiv.s");
        INSTR_FSQRT:      trace.printFInstr("fsqrt.s");
        INSTR_FSGNJS:     trace.printF2Instr("fsgnj.s");
        INSTR_FSGNJNS:    trace.printF2Instr("fsgnjn.s");
        INSTR_FSGNJXS:    trace.printF2Instr("fsgnjx.s");
        INSTR_FMIN:       trace.printF2Instr("fmin.s");
        INSTR_FMAX:       trace.printF2Instr("fmax.s");
        INSTR_FCVTWS:     trace.printFIInstr("fcvt.w.s");
        INSTR_FCVTWUS:    trace.printFIInstr("fcvt.wu.s");
        INSTR_FMVXS:      trace.printFIInstr("fmv.x.s");
        INSTR_FEQS:       trace.printF2IInstr("feq.s");
        INSTR_FLTS:       trace.printF2IInstr("flt.s");
        INSTR_FLES:       trace.printF2IInstr("fle.s");
        INSTR_FCLASS:     trace.printFIInstr("fclass.s");
        INSTR_FCVTSW:     trace.printIFInstr("fcvt.s.w");
        INSTR_FCVTSWU:    trace.printIFInstr("fcvt.s.wu");
        INSTR_FMVSX:      trace.printIFInstr("fmv.s.x");


        // opcodes with custom decoding
        {25'b?, OPCODE_LOAD}:       trace.printLoadInstr();
        {25'b?, OPCODE_LOAD_FP}:    trace.printLoadInstr();
        {25'b?, OPCODE_CUSTOM_0}:   trace.printLoadInstr();
        {25'b?, OPCODE_STORE}:      trace.printStoreInstr();
        {25'b?, OPCODE_STORE_FP}:   trace.printStoreInstr();
        {25'b?, OPCODE_CUSTOM_1}:   trace.printStoreInstr();
        {25'b?, OPCODE_CUSTOM_3}:   trace.printHwloopInstr();
        {25'b?, OPCODE_VECOP}:      trace.printVecInstr();
        default:           trace.printMnemonic("INVALID");
      endcase // unique case (instr)

      // visibility for simulator
      insn_disas = trace.str;
      insn_pc    = trace.pc;
      insn_val   = trace.instr;

      instr_ex.put(trace);
    end
  end // always @ (posedge clk)

endmodule
`endif
