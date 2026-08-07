import PortalPlaceholder from "../../shared/PortalPlaceholder";
export default function PMOPlaceholder(props: { title?: string; description?: string }) {
  return <PortalPlaceholder module="PMO" color="secondary" {...props} />;
}
