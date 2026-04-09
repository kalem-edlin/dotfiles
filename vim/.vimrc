syntax on
set number
set relativenumber
set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent
set clipboard=unnamed

" Over SSH, yank to local clipboard via OSC 52 (DCS passthrough for tmux)
if !empty($SSH_TTY)
  function! s:OscYank()
    let text = join(v:event.regcontents, "\n")
    let encoded = system('echo -n ' . shellescape(text) . ' | base64 | tr -d "\n"')
    if !empty($TMUX)
      call writefile(["\ePtmux;\e\e]52;c;" . encoded . "\a\e\\"], '/dev/tty', 'b')
    else
      call writefile(["\e]52;c;" . encoded . "\e\\"], '/dev/tty', 'b')
    endif
  endfunction
  autocmd TextYankPost * call s:OscYank()
endif

nnoremap <expr> j v:count ? 'j' : 'gj'
nnoremap <expr> k v:count ? 'k' : 'gk'
