-- BACCTODO replace by actual implementation

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity riscv_decrypt is
    generic (
        RATE : natural := 40;
        CAPACITY : natural := 160
    );
    port (
        clk : in std_logic;
        rst_n : in std_logic;
        data_in : in std_logic_vector(RATE-1 downto 0);
        active : in std_logic;   --! activates decryption, otherwise just passes through data
        key : in std_logic_vector(CAPACITY-1 downto 0);
        tag : in std_logic_vector(CAPACITY-1 downto 0);
        if_valid : in std_logic;
        csr : in std_logic_vector(2 downto 0); 
        busy : out std_logic;
        decrypt_valid : out std_logic;
        data_out : out std_logic_vector(31 downto 0)
    );
end riscv_decrypt;

architecture dummy of riscv_decrypt is
    signal int_clk : std_logic;
    signal int_rst_n : std_logic;
    signal int_data_in : std_logic_vector(RATE-1 downto 0);
    signal int_active : std_logic;
    signal int_key : std_logic_vector(CAPACITY-1 downto 0);
    signal int_tag : std_logic_vector(CAPACITY-1 downto 0);
    signal int_if_valid : std_logic;
    signal int_csr : std_logic_vector(2 downto 0);
    signal int_busy : std_logic;
    signal int_decrypt_valid : std_logic;
    signal int_data_out : std_logic_vector(31 downto 0);

    function to_hstring(slv: std_logic_vector) return string is
        constant hexlen : integer := (slv'length+3)/4;
        variable longslv : std_logic_vector(slv'length+3 downto 0) := (others => '0');
        variable hex : string(1 to hexlen);
        variable fourbit : std_logic_vector(3 downto 0);
    begin
        longslv(slv'length-1 downto 0) := slv;
        for i in hexlen-1 downto 0 loop
            fourbit := longslv(i*4+3 downto i*4);
            case fourbit is
                when "0000" => hex(hexlen-i) := '0';
                when "0001" => hex(hexlen-i) := '1';
                when "0010" => hex(hexlen-i) := '2';
                when "0011" => hex(hexlen-i) := '3';
                when "0100" => hex(hexlen-i) := '4';
                when "0101" => hex(hexlen-i) := '5';
                when "0110" => hex(hexlen-i) := '6';
                when "0111" => hex(hexlen-i) := '7';
                when "1000" => hex(hexlen-i) := '8';
                when "1001" => hex(hexlen-i) := '9';
                when "1010" => hex(hexlen-i) := 'A';
                when "1011" => hex(hexlen-i) := 'B';
                when "1100" => hex(hexlen-i) := 'C';
                when "1101" => hex(hexlen-i) := 'D';
                when "1110" => hex(hexlen-i) := 'E';
                when "1111" => hex(hexlen-i) := 'F';
                when "ZZZZ" => hex(hexlen-i) := 'Z';
                when "UUUU" => hex(hexlen-i) := 'U';
                when "XXXX" => hex(hexlen-i) := 'X';
                when others => hex(hexlen-i) := '?';
            end case;
        end loop;
        return hex;
    end function to_hstring;
begin
    
    busy <= not active;
    decrypt_valid <= active;
    data_out <= data_in(31 downto 0);

    process (clk)
    begin
        if rising_edge(clk) then
            report "decrypt: " & to_hstring(data_in) & "h" severity note;
        end if;
    end process;
  
    
end architecture dummy;