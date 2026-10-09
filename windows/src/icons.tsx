export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  const paths: Record<string, React.ReactNode> = {
    image: <><rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8" cy="8" r="1.5"/><path d="m4 17 5-5 4 4 3-4 4 5"/></>,
    clipboard: <><rect x="5" y="5" width="14" height="16" rx="3"/><rect x="9" y="3" width="6" height="4" rx="1"/><path d="M9 12h6M9 16h4"/></>,
    shelf: <><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 12h18M8 8h8M8 16h5"/></>,
    settings: <><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3"/><circle cx="16" cy="17" r="3"/></>,
    down: <><path d="M12 3v12m-5-5 5 5 5-5M4 17v4h16v-4"/></>,
    drop: <><path d="M12 3v10m-4-4 4 4 4-4M4 14l-1 7h18l-1-7M4 14h4l1 3h6l1-3h4"/></>,
    copy: <><rect x="8" y="8" width="13" height="13" rx="3"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></>,
    restore: <><path d="M4 10a8 8 0 1 1 1 8M4 4v6h6"/></>,
    folder: <path d="M3 7a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>,
    close: <path d="m6 6 12 12M6 18 18 6"/>,
    check: <path d="m5 12 4 4 10-10"/>,
    arrow: <path d="M4 12h16m-5-5 5 5-5 5"/>,
    compare: <><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M12 2v20m-6-10 2-2m-2 2 2 2m10-2-2-2m2 2-2 2"/></>,
    pin: <><path d="m9 3 6 0-1 6 4 4v2H6v-2l4-4ZM12 15v7"/></>,
    float: <><rect x="3" y="4" width="18" height="16" rx="3"/><rect x="12" y="11" width="7" height="7" rx="1"/></>,
    bolt: <path d="m13 2-9 12h7l-1 8 10-12h-7Z"/>,
    minus: <path d="M5 12h14"/>,
    help: <><circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 0 1 6 0c0 2-3 2-3 4m0 3h.01"/></>,
  };
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name] ?? paths.image}</svg>;
}
