'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { logout, getUser } from '@/lib/auth';
import {
  LayoutDashboard, Users, Ship, ShoppingCart,
  FileText, CreditCard, Building2, TrendingUp, LogOut, ChevronRight
} from 'lucide-react';

const navItems = [
  { href: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { href: '/suppliers', label: 'Suppliers', icon: Building2 },
  { href: '/vessels', label: 'Vessels', icon: Ship },
  { href: '/purchase-orders', label: 'Purchase Orders', icon: ShoppingCart },
  { href: '/invoices', label: 'Invoices', icon: FileText },
  { href: '/payments', label: 'Payments', icon: CreditCard },
  { href: '/bank-accounts', label: 'Bank Accounts', icon: Building2 },
  { href: '/exchange-rates', label: 'Exchange Rates', icon: TrendingUp },
  { href: '/users', label: 'Users', icon: Users },
];

export default function Sidebar() {
  const pathname = usePathname();
  const user = getUser();

  return (
    <aside className="w-64 bg-gray-900 border-r border-gray-800 flex flex-col min-h-screen">
      {/* Logo */}
      <div className="p-6 border-b border-gray-800">
        <div className="flex items-center gap-3">
          <div className="w-9 h-9 bg-blue-600 rounded-lg flex items-center justify-center">
            <span className="text-white font-bold text-sm">U</span>
          </div>
          <div>
            <p className="text-white font-semibold text-sm">UME Holding</p>
            <p className="text-gray-400 text-xs">PMS v1.0</p>
          </div>
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 p-4 space-y-1 overflow-y-auto">
        {navItems.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || pathname.startsWith(href + '/');
          return (
            <Link
              key={href}
              href={href}
              className={`flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors group ${
                active
                  ? 'bg-blue-600 text-white'
                  : 'text-gray-400 hover:text-white hover:bg-gray-800'
              }`}
            >
              <Icon size={18} />
              <span className="flex-1">{label}</span>
              {active && <ChevronRight size={14} />}
            </Link>
          );
        })}
      </nav>

      {/* User */}
      <div className="p-4 border-t border-gray-800">
        <div className="flex items-center gap-3 px-3 py-2 mb-2">
          <div className="w-8 h-8 bg-blue-600 rounded-full flex items-center justify-center">
            <span className="text-white text-xs font-semibold">
              {user?.full_name?.charAt(0) || 'A'}
            </span>
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-white text-xs font-medium truncate">{user?.full_name || 'Admin'}</p>
            <p className="text-gray-400 text-xs truncate">{user?.email}</p>
          </div>
        </div>
        <button
          onClick={logout}
          className="flex items-center gap-3 px-3 py-2 w-full text-gray-400 hover:text-red-400 hover:bg-gray-800 rounded-lg text-sm transition-colors"
        >
          <LogOut size={16} />
          Sign Out
        </button>
      </div>
    </aside>
  );
}
