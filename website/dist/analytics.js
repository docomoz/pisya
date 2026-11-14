const measurementId = document.querySelector('meta[name="pisa-ga-measurement-id"]')?.content;

if (measurementId && /^G-[A-Z0-9]+$/.test(measurementId)) {
  const script = document.createElement('script');
  script.async = true;
  script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(measurementId)}`;
  document.head.appendChild(script);

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  gtag('js', new Date());
  const pageLocation = window.location.origin + window.location.pathname;
  let pageReferrer = '';
  try { if (document.referrer) pageReferrer = new URL(document.referrer).origin; } catch {}
  gtag('config', measurementId, {
    page_location: pageLocation,
    page_referrer: pageReferrer,
    page_title: 'Pisa',
    allow_google_signals: false,
    allow_ad_personalization_signals: false,
  });

  // Only fixed event names and enumerated values are sent, never user input or URLs.
  const locations = new Set(['header', 'hero', 'install']);
  const destinations = new Set(['source', 'install_guide', 'privacy']);
  window.pisaTrack = (name, value) => {
    if (name === 'install_guide_click' && locations.has(value)) {
      gtag('event', name, { cta_location: value });
    } else if (name === 'github_click' && destinations.has(value)) {
      gtag('event', name, { github_destination: value });
    } else if (name === 'download_click' || name === 'copy_install_command' || name === 'contact_click') {
      gtag('event', name);
    }
  };
  document.addEventListener('click', event => {
    const link = event.target.closest?.('a');
    if (!link) return;
    const href = link.getAttribute('href');
    if (href === '#install-guide') {
      window.pisaTrack('install_guide_click', link.getAttribute('data-analytics-location'));
    } else if (href === '/download') {
      // Let the event leave the page before a same-tab download redirect.
      if (!event.defaultPrevented && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey && !link.hasAttribute('download') && (!link.target || link.target === '_self')) {
        event.preventDefault();
        let navigated = false;
        const navigate = () => {
          if (!navigated) { navigated = true; window.location.assign(link.href); }
        };
        gtag('event', 'download_click', { event_callback: navigate, event_timeout: 700 });
        window.setTimeout(navigate, 700);
      } else {
        window.pisaTrack('download_click');
      }
    } else if (href?.startsWith('https://github.com/docomoz/pisa')) {
      window.pisaTrack('github_click', link.getAttribute('data-analytics-destination'));
    } else if (href === 'https://t.me/docomoz') {
      window.pisaTrack('contact_click');
    }
  });
}
