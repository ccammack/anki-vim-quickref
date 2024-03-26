defmodule Cli do
 def parse_args(args) do
    {options, files, _} = OptionParser.parse(args, switches: [debug: :boolean])

    case files do
      [input_file, output_file] ->
        {options[:debug] || false, input_file, output_file}
      _ ->
        IO.puts("Usage: convert [--debug] quickref.txt vim-quickref.csv")
        System.halt(1)
    end
 end
end

defmodule Convert do
  defp match_line(line, pattern) do
    cleaned_line = String.replace(line, ~r/[\\^$.|?*+(){}[]]/, " ") |> String.replace(~r/\s+/, " ")
    cleaned_pattern = String.replace(pattern, ~r/[\\^$.|?*+(){}[]]/, " ") |> String.replace(~r/\s+/, " ")
    cleaned_line == cleaned_pattern or String.contains? cleaned_line, [cleaned_pattern]
  end

  defp match_sections(
         lines,
         start_pattern,
         stop_pattern,
         start_offset,
         stop_offset
       ) do
    Enum.reduce(lines, {false, []}, fn
      {line, value}, {inside_block, acc} ->
        if match_line(line, start_pattern) do
          if inside_block do
            # Skip if already inside a block
            {inside_block, acc}
          else
            # Enter block
            {true, [{start_pattern, value, value + start_offset} | acc]}
          end
        else
          if stop_pattern != "" and match_line(line, stop_pattern) do
            if inside_block do
              # Exit block
              {false, [{stop_pattern, value, value + stop_offset} | acc]}
            else
              # Skip if not inside a block
              {inside_block, acc}
            end
          else
            # Ignore other entries
            {inside_block, acc}
          end
        end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp validate_markers(markers, min_value, max_value) do
    # Make sure marker line numbers are in range and in order
    Enum.reduce_while(markers, nil, fn
      {_, _, number}, nil ->
        if number >= min_value and number <= max_value do
          {:cont, number}
        else
          {:halt, {:error, "Initial number is out of range"}}
        end

      {_, _, number}, last_number ->
        if number > last_number and number >= min_value and number <= max_value do
          {:cont, number}
        else
          {:halt, {:error, "Numbers are not strictly increasing or out of range"}}
        end
    end)
    |> case do
      {:error, message} -> {:error, message}
      _ -> :ok
    end
  end

  defp group_markers(markers, pairs) do
    case pairs do
      true ->
        # If the markers are pairs, validate the total count and pair them up
        if length(markers) |> rem(2) != 0 do
          {:error,
           :io.format(
             "Failed to match both start and end for requested patterns: %s",
             [
               inspect(markers, pretty: true)
             ]
           )}
        else
          # Chunk the markers into pairs and map each pair to a tuple
          {:ok,
           Enum.chunk_every(markers, 2)
           |> Enum.map(fn [start, stop] -> {start, stop} end)}
        end

      _ ->
        # If the markers are not pairs, double-up each marker to create a {start, start} pair
        {:ok, Enum.map(markers, fn start -> {start, start} end)}
    end
  end

  def collect_markers(
        lines,
        start_pattern,
        stop_pattern \\ "",
        start_offset \\ 0,
        stop_offset \\ 0
      ) do
    markers =
      Enum.with_index(lines)
      |> match_sections(start_pattern, stop_pattern, start_offset, stop_offset)
    case validate_markers(markers, 0, length(lines)) do
      {:error, message} ->
        {:error, :io.format("%s: %s", [message, inspect(lines, pretty: true)])}

      _ ->
        group_markers(markers, stop_pattern != "")
    end
  end

  defp debug_before(lines) do
    temp_dir = System.tmp_dir!()
    pid_str = :os.getpid()
    unix_str = DateTime.to_unix(DateTime.utc_now())
    prev = Path.join(temp_dir, "prev.#{pid_str}.#{unix_str}")
    next = Path.join(temp_dir, "next.#{pid_str}.#{unix_str}")
    File.write!(prev, Enum.join(lines, "\n") <> "\n")
    {prev, next}
  end

  defp debug_after(lines, {prev, next}) do
    File.write!(next, Enum.join(lines, "\n") <> "\n")
    command = "diff #{prev} #{next}"
    {output, exit_code} = System.cmd("sh", ["-c", command])
    case exit_code do
      0 -> IO.puts("No differences found.")
      1 -> IO.puts("Differences found.")
      _ -> IO.puts("An error occurred while running the diff utility.")
    end
    IO.puts(output)
    File.rm!(prev)
    File.rm!(next)
  end

  defp filter_lines(lines, markers, keep \\ false) do
    Enum.with_index(lines)
    |> Enum.filter(fn {_line, index} ->
      inside = Enum.any?(markers, fn {start_tuple, stop_tuple} ->
        start_index = elem(start_tuple, 2)
        stop_index = elem(stop_tuple, 2)
        index >= start_index and index <= stop_index
      end)
      inside && keep || !inside && !keep
    end)
    |> Enum.map(fn {line, _index} -> line end)
  end

  def delete_lines(
         lines,
         start_pattern,
         stop_pattern \\ "",
         start_offset \\ 0,
         stop_offset \\ 0
       ) do
    files = debug_before(lines)
    {_, markers} = collect_markers(lines, start_pattern, stop_pattern, start_offset, stop_offset)
    lines = filter_lines(lines, markers)
    debug_after(lines, files)
    lines
  end

  defp join_lines(lines) do
    Enum.reverse(lines)
    |> Enum.reduce({[], ""}, fn line, {acc, acc_line} ->
      if String.starts_with?(line, "|") do
        {acc ++ [line <> " " <> acc_line], ""}
      else
        {acc, line <> " " <> acc_line}
      end
    end)
    |> elem(0)
    |> Enum.reverse() 
   end

  def generate_card(title, card, output_file) do
    [first, second] = String.split(card, "\t")
    s = "(#{title})<br>#{first}\t(#{title})<br>#{second}\n"
    File.write(output_file, s, [:append])
  end

  defp clean_card_field(field) do
      field = Regex.replace(~r/\s+/, field, " ")
      field = Regex.replace(~r/\</, field, "[")
      field = Regex.replace(~r/\>/, field, "]")
      String.trim(field)
  end

  def generate_cards(lines, marker, output_file) do
    # extract cards for the section
    cards = filter_lines(lines, [marker], true)
    |> join_lines()
    |> Enum.map(fn line ->
      line = Regex.replace(~r/^\|[^|]*\|/, line, "")
      line = String.trim(line)
      [first, second] = String.split(line, "\t", parts: 2)
      first = clean_card_field(first)
      second = clean_card_field(second)
      first <> "  \t  " <> second
    end)

    # extract section title
    {start, _} = marker
    title = Enum.at(lines, elem(start, 1))
    title = Regex.replace(~r/^[^\s]+\s/, title, "")
    title = String.trim(title)
    title = Regex.replace(~r/\s+/, title, " ")

    Enum.each(cards, fn card -> generate_card(title, card, output_file) end)
  end

  def replace_line(lines, line) do
    {_ok, markers} = collect_markers(lines, line)
    {start, _stop} = List.first(markers)
    repl = elem(start, 0)
    index = elem(start, 2)
    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {_, ^index} -> repl
      {value, _} -> value
    end)
  end
end

args = System.argv()
{_debug, input_file, output_file} = Cli.parse_args(args)

# read input file
{:ok, contents} = File.read(input_file)
lines = String.split(contents, "\n", trim: true)

# write output header
output = """
#
# https://github.com/ccammack/anki-vim-quickref
#
# Import vim-quickref.csv into Anki with these Import Options:
#
#   Type:                 Basic (and reversed card)
#   Deck:                 vim-quickref
#   Fields separated by:  Tab
#   Allow HTML in fields: [checked]
#
# https://raw.githubusercontent.com/vim/vim/master/runtime/doc/quickref.txt
#
# #{List.first(lines)}
#
"""
File.write!(output_file, output)

end_pattern = "------------------------------------------------------------------------------"

# delete troublemakers
remain = lines
|> Convert.delete_lines("*quickref.txt* For Vim", end_pattern, 0, 2)
|> Convert.delete_lines("|pattern| Special characters in search patterns", "|search-offset| Offsets allowed after search command", 0, -1)
|> Convert.delete_lines("|search-offset| Offsets allowed after search command", end_pattern, 0, -1)
|> Convert.delete_lines("These only work when 'wrap' is off:")
|> Convert.delete_lines("in Visual block mode:")
|> Convert.delete_lines("|insert-index| alphabetical index of Insert mode commands")
|> Convert.delete_lines("leaving Insert mode:")
|> Convert.delete_lines("moving around:")
|> Convert.delete_lines("In Insert or Command-line mode:")
|> Convert.delete_lines("(change = delete text and enter Insert mode)")
|> Convert.delete_lines("|visual-index| list of Visual mode commands.")
|> Convert.delete_lines("Short explanation of each option: *option-list*", "'xtermcodes' request terminal codes from an xterm")
|> Convert.delete_lines("Context-sensitive completion on the command-line:")
|> Convert.delete_lines("|c_wildchar| 'wildchar' (default: <Tab>)", "'wildchar' will show the next ones")
|> Convert.delete_lines("*Q_ex* Special Ex characters", end_pattern)
|> Convert.delete_lines("Most useful Vim arguments (for full list see |startup-options|)", "|--| - read file from stdin")
|> Convert.delete_lines("Without !: Fail if changes have been made to the current buffer.", "With !: Discard any changes to the current buffer.")
|> Convert.delete_lines("in current window in new window ~", end_pattern, 0, -1)
|> Convert.delete_lines("*Q_ac* Automatic Commands", end_pattern)
|> Convert.delete_lines("|'foldmethod'| set foldmethod=manual manual folding", "set foldmethod=marker folding by 'foldmarker'")
|> Convert.delete_lines("vim:tw=78:ts=8:noet:ft=help:norl:")

# insert missing \t in lines that are missing it
|> Convert.replace_line("|:tp| :[count]tp[revious][!]  \t  jump to [count]'th previous matching tag")
|> Convert.replace_line("|:startinsert| :star[tinsert][!]  \t  start Insert mode, append when [!] used")
|> Convert.replace_line("|:startreplace| :startr[eplace][!]  \t  start Replace mode, at EOL when [!] used")
|> Convert.replace_line("|i_CTRL-O| CTRL-O {command}  \t  execute {command} and return to Insert mode")
|> Convert.replace_line("|i_<S-Left>| shift-left/right  \t  one word left/right")
|> Convert.replace_line("|i_CTRL-R| CTRL-R {register}  \t  insert the contents of a register")
|> Convert.replace_line("|v_g?| {visual}g?  \t  perform rot13 encoding on highlighted text")
|> Convert.replace_line("|:abbreviate| :ab[breviate] {lhs} {rhs}  \t  add abbreviation for {lhs} to {rhs}")
|> Convert.replace_line("|:noreabbrev| :norea[bbrev] [lhs] [rhs]  \t  like \":ab\", but don't remap [rhs]")
|> Convert.replace_line("|c_CTRL-R| CTRL-R {register}  \t  insert the contents of a register")
|> Convert.replace_line("|c_<S-Left>| <S-Left>/<S-Right>  \t  cursor one word left/right")

# append a final line
|> (fn l -> l ++ [end_pattern] end).()

# collect and write the sections to the output_file
{_ok, markers} = Convert.collect_markers(remain, "*Q_", end_pattern, 1, -1)
Enum.each(markers, fn marker -> Convert.generate_cards(remain, marker, output_file) end)

