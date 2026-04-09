syntax on
set number
set relativenumber
set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent
set clipboard=unnamed

" Over SSH, yank to local clipboard via OSC 52 escape sequence
" Ghostty intercepts this and writes to the local clipboard
if !empty($SSH_TTY)
  function! s:OscYank()
    let text = join(v:event.regcontents, "\n")
    let encoded = system('echo -n ' . shellescape(text) . ' | base64 | tr -d "\n"')
    call writefile(["\x1b]52;c;" . encoded . "\x1b\\"], '/dev/tty', 'b')
  endfunction
  autocmd TextYankPost * call s:OscYank()
endif

nnoremap <expr> j v:count ? 'j' : 'gj'
nnoremap <expr> k v:count ? 'k' : 'gk'
