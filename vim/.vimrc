syntax on
set number
set relativenumber
set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent
set clipboard=unnamed

" Over SSH, yank to local clipboard via yank.sh (handles OSC 52 + DCS passthrough)
if !empty($SSH_TTY)
  function! s:OscYank()
    let text = join(v:event.regcontents, "\n")
    call system('~/.config/tmux/scripts/yank.sh', text)
  endfunction
  autocmd TextYankPost * call s:OscYank()
endif

nnoremap <expr> j v:count ? 'j' : 'gj'
nnoremap <expr> k v:count ? 'k' : 'gk'
